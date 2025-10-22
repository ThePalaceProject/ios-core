//
//  AudiobookFileLogger.swift
//  Palace
//
//  Created by Maurice Carrier on 9/12/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

class AudiobookFileLogger: TPPErrorLogger {
  
  static let shared = AudiobookFileLogger()
  
  private var logsDirectoryUrl: URL? {
    let fileManager = FileManager.default
    let logsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AudiobookLogs")
    if let logsPath = logsPath, !fileManager.fileExists(atPath: logsPath.path) {
      try? fileManager.createDirectory(at: logsPath, withIntermediateDirectories: true, attributes: nil)
    }
    return logsPath
  }
  
  func getLogsDirectoryUrl() -> URL? {
    return logsDirectoryUrl
  }
  
  func logEvent(forBookId bookId: String, event: String) {
    guard let logsDirectoryUrl = logsDirectoryUrl, TPPSettings.shared.customMainFeedURL == nil else { return }

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
        try? fileHandle.seekToEnd()
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
      return try? String(contentsOf: logFileUrl)
    }
    
    let maxLogSize: Int64 = 1_000_000
    if fileSize > maxLogSize {
      Log.warn(#file, "Log file for \(bookId) is \(fileSize) bytes, truncating to last \(maxLogSize) bytes")
      guard let fileHandle = try? FileHandle(forReadingFrom: logFileUrl) else { return nil }
      defer { try? fileHandle.close() }
      
      let offset = max(0, fileSize - maxLogSize)
      try? fileHandle.seek(toOffset: UInt64(offset))
      
      if let data = try? fileHandle.readToEnd(), let truncatedLog = String(data: data, encoding: .utf8) {
        return "...[truncated \(offset) bytes]...\n" + truncatedLog
      }
    }
    
    return try? String(contentsOf: logFileUrl)
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
