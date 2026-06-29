import os
import Foundation

public final class Log {
    /// Subsystem identifier used for unified logging (OSLog).
    /// This makes Palace log entries identifiable when collecting device logs via OSLogStore.
    public static let subsystem = "org.thepalaceproject.palace"

    /// Host-app-provided forwarder for non-debug log lines (e.g. Firebase Crashlytics).
    /// Set once during app startup; access is serialized by an unfair lock so it
    /// is data-race-safe under Swift 6 strict concurrency.
    private static let _crashlyticsBridge = OSAllocatedUnfairLock<(any CrashlyticsLogBridge)?>(initialState: nil)
    public static var crashlyticsBridge: (any CrashlyticsLogBridge)? {
        get { _crashlyticsBridge.withLock { $0 } }
        set { _crashlyticsBridge.withLock { $0 = newValue } }
    }

    private static let palaceLog = OSLog(subsystem: subsystem, category: "Palace")

    /// Formats a timestamp for the non-debug forwarding path. Returns a fresh
    /// formatter per call rather than holding a shared mutable `DateFormatter`
    /// (a non-`Sendable` reference type) as global state. The path is rare
    /// (non-debug, error/fault only), so the allocation cost is negligible.
    private static func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func levelToString(_ level: OSLogType) -> String {
        switch level {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .error:
            return "ERROR"
        case .fault:
            return "FAULT"
        default:
            return "WARNING"
        }
    }

    private static func log(_ level: OSLogType, _ tag: String, _ message: String) {
        let tag = trimTag(tag)

        #if !targetEnvironment(simulator) && !DEBUG
        if level != .debug, let bridge = crashlyticsBridge {
            let timestamp = formattedTimestamp(Date())
            let formattedMsg = "[\(levelToString(level))] \(timestamp) \(tag): \(message)"
            bridge.log(formattedMsg)
        }
        #endif

        #if DEBUG
        if shouldThrottlePalaceLogging(level: level, tag: tag, message: message) {
            return
        }
        #endif

        os_log("%{public}@: %{public}@", log: palaceLog, type: level, tag, message)

        // Persist error and fault level messages to disk for cross-launch diagnostics.
        // OSLogStore entries may be pruned by the system, so PersistentLogger ensures
        // critical messages survive between sessions.
        if level == .error || level == .fault {
            Task {
                await PersistentLogger.shared.log(level: level, tag: tag, message: message)
            }
        }
    }

    /// Default-level log with no tag. Historically marked "objc compat only"
    /// but Swift code (notably the OPDS parsers) still relies on this short form.
    public static func log(_ message: String) {
        log(.default, "", message)
    }

    public static func debug(_ tag: String, _ message: String) {
        log(.debug, tag, message)
    }

    public static func info(_ tag: String, _ message: String) {
        log(.info, tag, message)
    }

    public static func warn(_ tag: String, _ message: String) {
        log(.default, tag, message)
    }

    public static func error(_ tag: String, _ message: String) {
        log(.error, tag, message)
    }

    /**
     Fault-level messages are intended for capturing system-level or
     multi-process errors only.
     */
    public static func fault(_ tag: String, _ message: String) {
        log(.fault, tag, message)
    }

    // MARK: - Performance Optimizations

    private static let palaceLogThrottleInterval: TimeInterval = 0.3
    /// Recent-message timestamps for log throttling, guarded by an unfair lock.
    /// Replaces the prior concurrent-queue + barrier (whose safety the Swift 6
    /// compiler could not prove): a single locked read-modify-write is simpler
    /// AND closes the read-then-async-write window the queue version had.
    private static let throttleState = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])

    private static func shouldThrottlePalaceLogging(level: OSLogType, tag: String, message: String) -> Bool {
        guard level != .error && level != .fault else { return false }

        let now = Date()
        let messageKey = "\(tag):\(message.prefix(30))"

        return throttleState.withLock { messages in
            if let lastTime = messages[messageKey],
               now.timeIntervalSince(lastTime) < palaceLogThrottleInterval {
                return true // Throttle this message
            }

            messages[messageKey] = now

            // Clean up old entries periodically to prevent memory growth.
            if messages.count > 50 {
                let cutoffTime = now.addingTimeInterval(-palaceLogThrottleInterval * 20)
                messages = messages.filter { $0.value > cutoffTime }
            }

            return false
        }
    }

    private static func trimTag(_ tag: String) -> String {
        guard tag.starts(with: "/") else {
            return tag
        }

        var components = tag.components(separatedBy: "/")
        let sourcesRootIndex = (components.firstIndex(of: "Palace") ?? 0) + 1

        if sourcesRootIndex < components.count {
            components.removeFirst(sourcesRootIndex)
        }

        guard !components.isEmpty else {
            return tag
        }

        return components.joined(separator: "/")
    }
}
