//
//  AudiobookFileLogger.swift
//  Palace
//
//  Created by Maurice Carrier on 9/12/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Protocol seam for test-time injection. Production call sites continue to
/// use `AudiobookFileLogger.shared`.
protocol AudiobookFileLogging {
    func getLogsDirectoryUrl() -> URL?
    func logEvent(forBookId bookId: String, event: String)
    func retrieveLog(forBookId bookId: String) -> String?
    func retrieveLogs(forBookIds bookIds: [String]) -> [String: String]
}

// `final` + `Sendable`: all stored properties are immutable value types
// (`Int64` and `URL?`), and every method is read-only over that state (file I/O
// via the thread-safe `FileManager`), so the type carries no shared mutable
// state. This makes `static let shared` concurrency-safe under Swift 6.
final class AudiobookFileLogger: AudiobookFileLogging, Sendable {

    static let shared = AudiobookFileLogger()

    private let maxTotalLogSize: Int64 = 10_000_000 // 10MB total for all audiobook logs

    /// Optional override of the directory where per-book log files are written.
    /// When non-nil, this URL is used directly (created on demand). When nil,
    /// the previous behavior of deriving from `.documentDirectory` is preserved
    /// for production singleton callers.
    private let logsRootURLOverride: URL?

    /// Designated initializer. Pass `logsRootURL` to redirect log writes to a
    /// caller-controlled directory (used by tests to isolate from on-disk
    /// shared state). Defaults to the production document-directory path.
    internal init(logsRootURL: URL? = nil) {
        self.logsRootURLOverride = logsRootURL
    }

    private var logsDirectoryUrl: URL? {
        let fileManager = FileManager.default
        let logsPath: URL?
        if let override = logsRootURLOverride {
            logsPath = override
        } else {
            logsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AudiobookLogs")
        }
        if let logsPath = logsPath {
            if !fileManager.fileExists(atPath: logsPath.path) {
                try? fileManager.createDirectory(at: logsPath, withIntermediateDirectories: true, attributes: nil)
            }
            logsPath.excludeFromBackup()
        }
        return logsPath
    }

    func getLogsDirectoryUrl() -> URL? {
        return logsDirectoryUrl
    }

    /// Cleans up old log files to prevent disk space issues
    private func cleanupOldLogsIfNeeded() {
        guard let logsDirectory = logsDirectoryUrl else { return }

        do {
            let logFiles = try FileManager.default.contentsOfDirectory(
                at: logsDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: .skipsHiddenFiles
            )

            // Calculate total size
            let totalSize = logFiles.reduce(Int64(0)) { total, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total + Int64(size)
            }

            // If over limit, delete oldest files
            if totalSize > maxTotalLogSize {
                let sortedFiles = logFiles.sorted { file1, file2 in
                    let date1 = (try? file1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let date2 = (try? file2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return date1 < date2 // Oldest first
                }

                // Delete oldest files until under limit
                var currentSize = totalSize
                for oldFile in sortedFiles {
                    if currentSize <= maxTotalLogSize { break }
                    let fileSize = (try? oldFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    try? FileManager.default.removeItem(at: oldFile)
                    currentSize -= Int64(fileSize)
                }
            }
        } catch {
            print("⚠️ Failed to cleanup old audiobook logs: \(error.localizedDescription)")
        }
    }

    func logEvent(forBookId bookId: String, event: String) {
        guard let logsDirectoryUrl = logsDirectoryUrl else { return }

        // Cleanup old logs periodically to prevent disk space issues
        cleanupOldLogsIfNeeded()

        print("New event logged: \(event.description)")
        let logFileUrl = logsDirectoryUrl.appendingPathComponent("\(bookId).log")
        let logMessage = "\(Date()): \(event)\n"
        let maxLogFileSize: Int64 = 2_000_000

        if FileManager.default.fileExists(atPath: logFileUrl.path) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: logFileUrl.path)[.size] as? Int64) ?? 0

            if fileSize > maxLogFileSize {
                try? FileManager.default.removeItem(at: logFileUrl)
                try? "...[previous log truncated due to size]...\n\(logMessage)".write(to: logFileUrl, atomically: true, encoding: .utf8)
            } else if let fileHandle = try? FileHandle(forWritingTo: logFileUrl) {
                defer { try? fileHandle.close() }
                _ = try? fileHandle.seekToEnd()
                if let logData = logMessage.data(using: .utf8) {
                    fileHandle.write(logData)
                }
            }
        } else {
            try? logMessage.write(to: logFileUrl, atomically: true, encoding: .utf8)
        }
    }

    func retrieveLog(forBookId bookId: String) -> String? {
        guard let logsDirectoryUrl = logsDirectoryUrl else { return nil }
        let logFileUrl = logsDirectoryUrl.appendingPathComponent("\(bookId).log")

        guard let fileSize = try? FileManager.default.attributesOfItem(atPath: logFileUrl.path)[.size] as? Int64 else {
            return try? String(contentsOf: logFileUrl, encoding: .utf8)
        }

        let maxLogSize: Int64 = 1_000_000
        if fileSize > maxLogSize {
            print("⚠️ Log file for \(bookId) is \(fileSize) bytes, truncating to last \(maxLogSize) bytes")
            guard let fileHandle = try? FileHandle(forReadingFrom: logFileUrl) else { return nil }
            defer { try? fileHandle.close() }

            let offset = max(0, fileSize - maxLogSize)
            try? fileHandle.seek(toOffset: UInt64(offset))

            if let data = try? fileHandle.readToEnd(), let truncatedLog = String(data: data, encoding: .utf8) {
                return "...[truncated \(offset) bytes]...\n" + truncatedLog
            }
        }

        return try? String(contentsOf: logFileUrl, encoding: .utf8)
    }

    func retrieveLogs(forBookIds bookIds: [String]) -> [String: String] {
        var logs: [String: String] = [:]
        for bookId in bookIds {
            if let log = retrieveLog(forBookId: bookId) {
                logs[bookId] = log
            }
        }
        return logs
    }
}

// Wave 1c: dev-tools log-email seam. Internal witness is fine — the
// conforming type is internal (public-witness rule applies to public types).
extension AudiobookFileLogger: LogArchiveExporting {
    func logArchiveDirectoryURL() -> URL? {
        getLogsDirectoryUrl()
    }
}
