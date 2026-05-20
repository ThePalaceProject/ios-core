//
//  PersistentLogger.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import os.log

/// Public protocol seam for `PersistentLogger`. Production call sites
/// continue to use `PersistentLogger.shared`; tests construct a hermetic
/// instance via `public init(logsRootURL:)`.
public protocol PersistentLogging {
    func log(level: OSLogType, tag: String, message: String) async
    func retrieveAllLogs() async -> String
    func clearLogs() async
}

/// Actor-based persistent file logger for error diagnostics
/// Complements Crashlytics by providing local log history
public actor PersistentLogger: PersistentLogging {
    public static let shared = PersistentLogger()

    private let maxLogFileSize: Int64 = 5_000_000 // 5MB
    private let maxLogFiles = 5
    private let logFileName = "palace_error.log"

    /// Optional override of the directory where log files are persisted.
    /// When nil, falls back to the default `<Documents>/Logs` path.
    private let logsRootURLOverride: URL?

    private var currentLogFile: URL?
    private var logFileHandle: FileHandle?

    /// Designated initializer. Pass `logsRootURL` to redirect writes to a
    /// caller-controlled directory. The previous parameterless ctor was
    /// `private`; the public seam is required for hermetic unit tests.
    /// Production singleton accessor (`PersistentLogger.shared`) is unchanged.
    public init(logsRootURL: URL? = nil) {
        self.logsRootURLOverride = logsRootURL
        Task {
            await setupLogFile()
        }
    }

    deinit {
        try? logFileHandle?.close()
    }

    // MARK: - Setup

    private func setupLogFile() {
        let logsDirectory = getLogsDirectory()

        do {
            if !FileManager.default.fileExists(atPath: logsDirectory.path) {
                try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            }

            currentLogFile = logsDirectory.appendingPathComponent(logFileName)

            // Rotate if too large
            if let currentFile = currentLogFile {
                if FileManager.default.fileExists(atPath: currentFile.path) {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: currentFile.path)
                    let fileSize = attributes?[.size] as? Int64 ?? 0

                    if fileSize > maxLogFileSize {
                        rotateLogFiles()
                    }
                }

                // Open or create log file
                if !FileManager.default.fileExists(atPath: currentFile.path) {
                    FileManager.default.createFile(atPath: currentFile.path, contents: nil)
                }

                logFileHandle = try? FileHandle(forWritingTo: currentFile)
                _ = try? logFileHandle?.seekToEnd()
            }
        } catch {
            os_log("Failed to setup log file: %{public}@", type: .error, error.localizedDescription)
        }
    }

    // MARK: - Logging

    /// Logs an error message to persistent storage
    public func log(level: OSLogType, tag: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelString = levelToString(level)
        let formattedMessage = "[\(timestamp)] [\(levelString)] \(tag): \(message)\n"

        guard let data = formattedMessage.data(using: .utf8) else { return }

        do {
            if logFileHandle == nil {
                setupLogFile()
            }

            logFileHandle?.write(data)

            // Check if rotation needed
            if let currentFile = currentLogFile {
                let attributes = try? FileManager.default.attributesOfItem(atPath: currentFile.path)
                let fileSize = attributes?[.size] as? Int64 ?? 0

                if fileSize > maxLogFileSize {
                    try? logFileHandle?.close()
                    logFileHandle = nil
                    rotateLogFiles()
                    setupLogFile()
                }
            }
        }
    }

    private func levelToString(_ level: OSLogType) -> String {
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
            return "WARN"
        }
    }

    // MARK: - Log Rotation

    private func rotateLogFiles() {
        let logsDirectory = getLogsDirectory()
        let baseFileName = "palace_error"

        // Delete oldest log file
        let oldestFile = logsDirectory.appendingPathComponent("\(baseFileName).\(maxLogFiles - 1).log")
        try? FileManager.default.removeItem(at: oldestFile)

        // Rotate existing log files
        for i in stride(from: maxLogFiles - 2, through: 0, by: -1) {
            let oldName = i == 0 ? "\(baseFileName).log" : "\(baseFileName).\(i).log"
            let newName = "\(baseFileName).\(i + 1).log"

            let oldURL = logsDirectory.appendingPathComponent(oldName)
            let newURL = logsDirectory.appendingPathComponent(newName)

            if FileManager.default.fileExists(atPath: oldURL.path) {
                try? FileManager.default.moveItem(at: oldURL, to: newURL)
            }
        }
    }

    // MARK: - Log Retrieval

    /// Retrieves all log files as a single string
    public func retrieveAllLogs() -> String {
        let logsDirectory = getLogsDirectory()
        var allLogs = "=== Palace Persistent Logs ===\n"
        allLogs += "Retrieved: \(Date())\n\n"

        // Read all log files in order (newest to oldest)
        for i in 0..<maxLogFiles {
            let fileName = i == 0 ? logFileName : "palace_error.\(i).log"
            let fileURL = logsDirectory.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: fileURL.path),
               let logContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                allLogs += "=== Log File: \(fileName) ===\n"
                allLogs += logContent
                allLogs += "\n\n"
            }
        }

        return allLogs
    }

    /// Clears all log files
    public func clearLogs() {
        try? logFileHandle?.close()
        logFileHandle = nil

        let logsDirectory = getLogsDirectory()

        for i in 0..<maxLogFiles {
            let fileName = i == 0 ? logFileName : "palace_error.\(i).log"
            let fileURL = logsDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }

        setupLogFile()
    }

    // MARK: - Helpers

    private func getLogsDirectory() -> URL {
        if let override = logsRootURLOverride {
            return override
        }
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Logs")
        }
        return documentsDirectory.appendingPathComponent("Logs")
    }
}
