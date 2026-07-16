#if canImport(UIKit)
import Foundation
import UIKit
import Network
import OSLog
import os
import AVFoundation
import TriageBotCore

/// iOS-native ContextProvider that pulls everything obtainable from system
/// frameworks alone. Palace-specific fields (library UUID, distributor,
/// auth type) come from a `PalaceFields` struct injected at construction;
/// keeping that decoupled means the package can ship into another Palace-
/// family app without modification.
public final class DefaultIosContextProvider: ContextProvider {
    /// Fields the host app knows about and we don't — passed in by the
    /// caller right before snapshotting. iOS-only frameworks fill the rest.
    public struct PalaceFields: Sendable {
        public let libraryName: String?
        public let libraryUUID: String?
        public let distributor: String?
        public let authType: String?
        /// Raw library card barcode. Hashed by ContextRedactor before it lands
        /// in state and omitted from the ticket by default (PP-4807).
        public let barcode: String?

        public init(
            libraryName: String? = nil,
            libraryUUID: String? = nil,
            distributor: String? = nil,
            authType: String? = nil,
            barcode: String? = nil
        ) {
            self.libraryName = libraryName
            self.libraryUUID = libraryUUID
            self.distributor = distributor
            self.authType = authType
            self.barcode = barcode
        }
    }

    private let palaceFields: @Sendable () async -> PalaceFields
    private let logSubsystem: String?
    private let logWindowSeconds: TimeInterval
    private let logMaxLines: Int
    private static let processStartTime: Date = Date()

    /// - Parameters:
    ///   - palaceFields: Async closure the host calls so the provider can ask
    ///     for fresh values right before snapshotting. Keeps Palace's
    ///     `TPPLibraryAccountsProvider` out of the package surface.
    ///   - logSubsystem: OSLog subsystem to tail (typically the app's bundle
    ///     id). When nil, recentLogLines stays empty.
    ///   - logWindowSeconds: how far back to pull log entries. Default 30 min
    ///     so the attached log file is rich enough for triage without
    ///     blowing past typical email attachment limits.
    ///   - logMaxLines: hard cap on number of log lines included, regardless
    ///     of window. Keeps the email under ~50KB even for chatty sessions.
    public init(
        palaceFields: @escaping @Sendable () async -> PalaceFields,
        logSubsystem: String? = nil,
        logWindowSeconds: TimeInterval = 1800,
        logMaxLines: Int = 300
    ) {
        self.palaceFields = palaceFields
        self.logSubsystem = logSubsystem
        self.logWindowSeconds = logWindowSeconds
        self.logMaxLines = logMaxLines
    }

    public func captureSnapshot() async -> ContextSnapshot {
        let fields = await palaceFields()
        let network = await currentNetworkState()
        let logs = recentLogs()
        let now = Date()

        return ContextSnapshot(
            appVersion: bundleString(forInfoKey: "CFBundleShortVersionString") ?? "unknown",
            appBuild: bundleString(forInfoKey: kCFBundleVersionKey as String) ?? "unknown",
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: deviceModelIdentifier(),
            libraryName: fields.libraryName,
            libraryUUID: fields.libraryUUID,
            distributor: fields.distributor,
            authType: fields.authType,
            networkState: network,
            freeStorageBytes: freeStorageBytes(),
            recentLogLines: logs,
            crashlyticsFingerprints: [],
            capturedAt: now,
            audioOutputRoute: currentAudioOutputRoute(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            appUptimeSeconds: Int64(now.timeIntervalSince(Self.processStartTime)),
            buildChannel: detectBuildChannel(),
            availableMemoryMB: availableMemoryMB(),
            libraryBarcode: fields.barcode
        )
    }

    /// Cheap app/OS/device-only snapshot (PP-4809). Used when the patron turns
    /// "Include diagnostics" OFF — no log tail, no network probe, no Palace
    /// account fields, no barcode. Just the basics support always needs.
    public func minimalSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            appVersion: bundleString(forInfoKey: "CFBundleShortVersionString") ?? "unknown",
            appBuild: bundleString(forInfoKey: kCFBundleVersionKey as String) ?? "unknown",
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: deviceModelIdentifier(),
            capturedAt: Date(),
            buildChannel: detectBuildChannel()
        )
    }

    // MARK: - Bundle / device

    private func bundleString(forInfoKey key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private func deviceModelIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.trimmingCharacters(in: .controlCharacters)
    }

    private func freeStorageBytes() -> Int64? {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Network

    private func currentNetworkState() async -> String? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "TriageBotIOS.NWPathMonitor")
        // `resumed` is read+mutated by two closures the compiler can't prove are
        // serialized (the path handler + the timeout block). They do in fact both
        // run on `queue`, but Swift 6 requires the guard be provably race-free, so
        // hoist the flag into a lock (playbook: OSAllocatedUnfairLock, never
        // nonisolated(unsafe)). `claimResume()` returns true exactly once.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let claimResume: @Sendable () -> Bool = {
            resumed.withLock { alreadyResumed in
                if alreadyResumed { return false }
                alreadyResumed = true
                return true
            }
        }
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            monitor.pathUpdateHandler = { path in
                guard claimResume() else { return }
                let state: String
                if path.status == .satisfied {
                    if path.usesInterfaceType(.wifi) { state = "wifi" }
                    else if path.usesInterfaceType(.cellular) { state = "cellular" }
                    else if path.usesInterfaceType(.wiredEthernet) { state = "wired" }
                    else { state = "other" }
                } else {
                    state = "offline"
                }
                monitor.cancel()
                continuation.resume(returning: state)
            }
            monitor.start(queue: queue)
            // 250ms hard cap — we don't block snapshot for a flaky path probe
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                guard claimResume() else { return }
                monitor.cancel()
                continuation.resume(returning: nil)
            }
        }
        return value
    }

    // MARK: - Logs

    /// Tails the configured log window for the configured subsystem.
    /// Returns an empty array if the store can't be opened, the subsystem
    /// wasn't configured, or no lines matched. Lines are NOT redacted here —
    /// the redactor runs inside the reducer once the snapshot lands.
    private func recentLogs() -> [String] {
        guard let subsystem = logSubsystem else { return [] }
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-logWindowSeconds))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(at: since, matching: predicate)
            var lines: [String] = []
            for entry in entries {
                if let logEntry = entry as? OSLogEntryLog {
                    let levelTag: String
                    switch logEntry.level {
                    case .error, .fault: levelTag = "[E] "
                    case .info: levelTag = "[I] "
                    case .debug: levelTag = "[D] "
                    default: levelTag = "[ ] "
                    }
                    let ts = ISO8601DateFormatter().string(from: logEntry.date)
                    lines.append("\(ts) \(levelTag)\(logEntry.composedMessage)")
                    if lines.count >= logMaxLines { break }
                }
            }
            return lines
        } catch {
            return []
        }
    }

    // MARK: - Expanded diagnostics

    /// Active audio output route, normalized to a short string. Returns nil
    /// when AVAudioSession isn't available (process not yet activated audio).
    private func currentAudioOutputRoute() -> String? {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let port = route.outputs.first else { return nil }
        return port.portType.rawValue
    }

    /// Available physical memory in MB. Uses os_proc_available_memory (iOS 13+).
    private func availableMemoryMB() -> Int64? {
        let bytes = os_proc_available_memory()
        guard bytes > 0 else { return nil }
        return Int64(bytes / (1024 * 1024))
    }

    /// Distribution channel inferred from the App Store receipt path.
    /// - "appstore" when the production receipt is present
    /// - "testflight" when the sandbox receipt is present
    /// - "debug" when no receipt is present (typical of Xcode debug builds)
    /// - "unknown" if we can't tell
    private func detectBuildChannel() -> String? {
        guard let url = Bundle.main.appStoreReceiptURL else { return "debug" }
        switch url.lastPathComponent {
        case "sandboxReceipt": return "testflight"
        case "receipt":        return "appstore"
        default:               return "unknown"
        }
    }
}
#endif
