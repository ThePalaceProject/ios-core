//
//  DeviceLogCollector.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import OSLog
import PalaceLogging

/// A single collected log record, decoupled from `OSLogEntry`.
///
/// This is the unit the formatting / counting / truncation logic operates on.
/// Production adapts `OSLogEntryLog` / `OSLogEntrySignpost` into it (see
/// `DeviceLogCollector.liveOSLogStoreEntries`); tests build fixtures directly,
/// so the collector's logic is exercised without scanning the live process log
/// store. `OSLogEntry` subclasses aren't publicly constructible, which is
/// exactly why the seam is a value type rather than the OS type.
struct DeviceLogEntry: Sendable {
    /// Mirrors `OSLogEntryLog.Level` as a closed, `Sendable` value so the seam
    /// type carries no dependency on the OSLog SDK's own (non-`Sendable`) enum.
    enum Level: Sendable {
        case undefined, debug, info, notice, error, fault, other
    }
    enum Kind: Sendable {
        case log(level: Level)
        case signpost
    }
    let date: Date
    let subsystem: String
    let category: String
    let message: String
    let kind: Kind
}

/// Collects device-level logs from the unified logging system (OSLogStore).
///
/// This provides comprehensive diagnostic logs similar to Android's logcat output,
/// including all os_log messages from the Palace process — framework logs, network
/// activity, and application-level logging that may not be captured by PersistentLogger.
actor DeviceLogCollector {
    static let shared = DeviceLogCollector()

    /// Maximum number of log entries to collect to prevent excessive memory usage
    private let maxEntries: Int

    /// Maximum output size in bytes (~10MB uncompressed text)
    private let maxOutputBytes: Int

    /// Source of log records. Defaults to the live process OSLogStore.
    ///
    /// Injectable so tests drive the format/count/truncation logic against a
    /// bounded fixture instead of `OSLogStore(scope: .currentProcessIdentifier)`
    /// — whose entry volume grows with every test that ran before, making a live
    /// scan both slow and load-dependent under full-suite CI (the DeviceLogCollector
    /// 120s full-suite hang). The `maxEntries` argument lets the source bound its
    /// own walk so the expensive scan terminates early, mirroring the pre-refactor
    /// in-loop cap.
    private let entrySource: @Sendable (_ days: Int, _ maxEntries: Int) throws -> [DeviceLogEntry]

    init(
        entrySource: @escaping @Sendable (_ days: Int, _ maxEntries: Int) throws -> [DeviceLogEntry] = DeviceLogCollector.liveOSLogStoreEntries,
        maxEntries: Int = 50_000,
        maxOutputBytes: Int = 10_000_000
    ) {
        self.entrySource = entrySource
        self.maxEntries = maxEntries
        self.maxOutputBytes = maxOutputBytes
    }

    // MARK: - Public API

    /// Collects device logs from the unified logging system for the specified time range.
    /// - Parameter days: Number of days of logs to retrieve (default: 7)
    /// - Returns: Formatted log data ready for export
    func collectLogs(lastDays days: Int = 7) -> Data {
        var output = "=== Device Logs (OSLogStore) ===\n"
        output += "Generated: \(Date())\n"
        output += "Time Range: Last \(days) day(s)\n"
        output += "Note: These are full process logs from the iOS unified logging system.\n\n"

        do {
            // The source bounds its own walk at `maxEntries` (the expensive scan),
            // so the returned array is already capped; the byte budget is applied
            // here during formatting.
            let entries = try entrySource(days, maxEntries)

            var entryCount = 0
            var byteCount = 0
            var truncated = false

            for entry in entries {
                if byteCount >= maxOutputBytes {
                    truncated = true
                    break
                }
                let line = format(entry)
                output += line
                byteCount += line.utf8.count
                entryCount += 1
            }

            // The source returning a full `maxEntries` batch means more entries
            // existed than we collected — same "truncated" signal the old in-loop
            // entry cap produced.
            if !truncated && entries.count >= maxEntries {
                truncated = true
            }
            if truncated {
                output += "\n[Log output truncated at \(entryCount) entries / \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))]\n"
            }

            output += "\n=== End Device Logs (\(entryCount) entries) ===\n"

        } catch {
            output += "Failed to access OSLogStore: \(error.localizedDescription)\n"
            output += "This may occur if the app lacks access to the log store.\n"
        }

        return Data(output.utf8)
    }

    // MARK: - Live OSLogStore source (production default)

    /// The production entry source: reads the current process's unified log
    /// store and adapts each record into a `DeviceLogEntry`. Bounds its walk at
    /// `maxEntries` so the scan terminates early instead of decoding the entire
    /// (potentially enormous) store. This is the only live-store reader; tests
    /// substitute a fixture source and never reach it.
    static func liveOSLogStoreEntries(days: Int, maxEntries: Int) throws -> [DeviceLogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let position = store.position(date: startDate)
        let rawEntries = try store.getEntries(at: position)

        var result: [DeviceLogEntry] = []
        result.reserveCapacity(min(maxEntries, 4096))
        for entry in rawEntries {
            if result.count >= maxEntries { break }
            if let logEntry = entry as? OSLogEntryLog {
                result.append(DeviceLogEntry(
                    date: logEntry.date,
                    subsystem: logEntry.subsystem,
                    category: logEntry.category,
                    message: logEntry.composedMessage,
                    kind: .log(level: mapLevel(logEntry.level))
                ))
            } else if let signpostEntry = entry as? OSLogEntrySignpost {
                result.append(DeviceLogEntry(
                    date: signpostEntry.date,
                    subsystem: signpostEntry.subsystem,
                    category: signpostEntry.category,
                    message: signpostEntry.composedMessage,
                    kind: .signpost
                ))
            }
        }
        return result
    }

    // MARK: - Formatting

    private func format(_ entry: DeviceLogEntry) -> String {
        let timestamp = formatDate(entry.date)
        let subsystem = entry.subsystem.isEmpty ? "-" : entry.subsystem
        let category = entry.category.isEmpty ? "-" : entry.category

        switch entry.kind {
        case .log(let level):
            return "[\(timestamp)] [\(levelString(for: level))] [\(subsystem)/\(category)] \(entry.message)\n"
        case .signpost:
            return "[\(timestamp)] [SIGNPOST] [\(subsystem)/\(category)] \(entry.message)\n"
        }
    }

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func levelString(for level: DeviceLogEntry.Level) -> String {
        switch level {
        case .undefined:
            return "UNDEF"
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO "
        case .notice:
            return "NOTE "
        case .error:
            return "ERROR"
        case .fault:
            return "FAULT"
        case .other:
            return "OTHER"
        }
    }

    /// Maps the OSLog SDK level onto our closed `Sendable` mirror. Kept adjacent
    /// to `levelString` so the two stay in sync.
    private static func mapLevel(_ level: OSLogEntryLog.Level) -> DeviceLogEntry.Level {
        switch level {
        case .undefined: return .undefined
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .error: return .error
        case .fault: return .fault
        @unknown default: return .other
        }
    }

    // MARK: - Date Formatter

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
