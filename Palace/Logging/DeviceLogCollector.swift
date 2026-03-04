//
//  DeviceLogCollector.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import OSLog

/// Collects device-level logs from the unified logging system (OSLogStore).
///
/// This provides comprehensive diagnostic logs similar to Android's logcat output,
/// including all os_log messages from the Palace process — framework logs, network
/// activity, and application-level logging that may not be captured by PersistentLogger.
actor DeviceLogCollector {
    static let shared = DeviceLogCollector()

    /// Maximum number of log entries to collect to prevent excessive memory usage
    private let maxEntries = 50_000

    /// Maximum output size in bytes (~10MB uncompressed text)
    private let maxOutputBytes = 10_000_000

    private init() {}

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
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            let position = store.position(date: startDate)

            let entries = try store.getEntries(at: position)

            var entryCount = 0
            var byteCount = 0

            for entry in entries {
                guard entryCount < maxEntries, byteCount < maxOutputBytes else {
                    output += "\n[Log output truncated at \(entryCount) entries / \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))]\n"
                    break
                }

                if let logEntry = entry as? OSLogEntryLog {
                    let line = formatLogEntry(logEntry)
                    output += line
                    byteCount += line.utf8.count
                    entryCount += 1
                } else if let signpostEntry = entry as? OSLogEntrySignpost {
                    let line = formatSignpostEntry(signpostEntry)
                    output += line
                    byteCount += line.utf8.count
                    entryCount += 1
                }
            }

            output += "\n=== End Device Logs (\(entryCount) entries) ===\n"

        } catch {
            output += "Failed to access OSLogStore: \(error.localizedDescription)\n"
            output += "This may occur if the app lacks access to the log store.\n"
        }

        return Data(output.utf8)
    }

    // MARK: - Formatting

    private func formatLogEntry(_ entry: OSLogEntryLog) -> String {
        let timestamp = formatDate(entry.date)
        let level = levelString(for: entry.level)
        let subsystem = entry.subsystem.isEmpty ? "-" : entry.subsystem
        let category = entry.category.isEmpty ? "-" : entry.category
        let message = entry.composedMessage

        return "[\(timestamp)] [\(level)] [\(subsystem)/\(category)] \(message)\n"
    }

    private func formatSignpostEntry(_ entry: OSLogEntrySignpost) -> String {
        let timestamp = formatDate(entry.date)
        let subsystem = entry.subsystem.isEmpty ? "-" : entry.subsystem
        let category = entry.category.isEmpty ? "-" : entry.category

        return "[\(timestamp)] [SIGNPOST] [\(subsystem)/\(category)] \(entry.composedMessage)\n"
    }

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func levelString(for level: OSLogEntryLog.Level) -> String {
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
        @unknown default:
            return "OTHER"
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
