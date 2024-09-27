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
    
    if FileManager.default.fileExists(atPath: logFileUrl.path) {
      if let fileHandle = try? FileHandle(forWritingTo: logFileUrl) {
        fileHandle.seekToEndOfFile()
        if let logData = logMessage.data(using: .utf8) {
          fileHandle.write(logData)
        }
        fileHandle.closeFile()
      }
    } else {
      try? logMessage.write(to: logFileUrl, atomically: true, encoding: .utf8)
    }
  }
  
  func retrieveLog(forBookId bookId: String) -> String? {
    guard let logsDirectoryUrl = logsDirectoryUrl else { return nil }
    let logFileUrl = logsDirectoryUrl.appendingPathComponent("\(bookId).log")
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
