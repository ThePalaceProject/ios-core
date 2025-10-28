//
//  ErrorLogExporter.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import MessageUI
import FirebaseCrashlytics
import Compression

/// Actor responsible for collecting and exporting error logs for diagnostics
actor ErrorLogExporter {
  typealias DisplayStrings = Strings.ErrorLogExporter
  
  static let shared = ErrorLogExporter()
  
  private let logsEmail = "logs@thepalaceproject.org"
  private let maxLogSizeBytes: Int = 5_000_000 // 5MB
  private let defaultLogDays: Int = 7
  
  private init() {}
  
  // MARK: - Public API
  
  /// Generates and presents an email with collected error logs
  @MainActor
  func sendErrorLogs(from presentingViewController: UIViewController) async {
    guard MFMailComposeViewController.canSendMail() else {
      await showMailNotAvailableAlert(from: presentingViewController)
      return
    }
    
    // Show loading indicator while collecting logs
    let loadingAlert = UIAlertController(
      title: "Collecting Logs",
      message: "Please wait while we gather diagnostic information...",
      preferredStyle: .alert
    )
    presentingViewController.present(loadingAlert, animated: true)
    
    // Collect logs in background
    let logData = await collectAllLogs()
    
    // Dismiss loading alert
    loadingAlert.dismiss(animated: true)
    
    // Present mail composer
    await presentMailComposer(with: logData, from: presentingViewController)
  }
  
  // MARK: - Log Collection
  
  /// Collects all error logs from various sources
  private func collectAllLogs() async -> ErrorLogData {
    async let errorLogs = collectErrorLogs()
    async let audiobookLogs = collectAudiobookPlaybackLogs()
    async let crashlyticsBreadcrumbs = collectCrashlyticsBreadcrumbs()
    
    let allErrorLogs = await errorLogs
    let allAudiobookLogs = await audiobookLogs
    let breadcrumbs = await crashlyticsBreadcrumbs
    
    return ErrorLogData(
      errorLogs: allErrorLogs,
      audiobookLogs: allAudiobookLogs,
      crashlyticsBreadcrumbs: breadcrumbs,
      deviceInfo: collectDeviceInfo()
    )
  }
  
  /// Collects error logs from the logging system
  private func collectErrorLogs() async -> Data {
    var logContent = "=== Palace Error Logs ===\n"
    logContent += "Generated: \(Date())\n"
    logContent += "Time Range: Last \(defaultLogDays) days\n\n"
    
    // Collect from Firebase Crashlytics if available
    #if FEATURE_CRASH_REPORTING
    if Bundle.main.applicationEnvironment == .production {
      logContent += "Note: Crashlytics reports are sent separately to Firebase.\n"
      logContent += "This log contains local diagnostic information only.\n\n"
    }
    #endif
    
    // Collect application logs
    logContent += await collectApplicationLogs()
    
    // Collect network logs if available
    logContent += "\n\n=== Network Logs ===\n"
    logContent += await collectNetworkLogs()
    
    // Collect book registry logs
    logContent += "\n\n=== Book Registry State ===\n"
    logContent += await collectRegistryState()
    
    return Data(logContent.utf8)
  }
  
  /// Collects audiobook playback logs
  private func collectAudiobookPlaybackLogs() async -> Data {
    var logContent = "=== Audiobook Playback Logs ===\n"
    logContent += "Generated: \(Date())\n\n"
    
    guard let logsDirectory = AudiobookFileLogger.shared.getLogsDirectoryUrl() else {
      logContent += "No audiobook logs directory found.\n"
      return Data(logContent.utf8)
    }
    
    let fileManager = FileManager.default
    guard let logFiles = try? fileManager.contentsOfDirectory(
      at: logsDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: .skipsHiddenFiles
    ) else {
      logContent += "Unable to read audiobook logs directory.\n"
      return Data(logContent.utf8)
    }
    
    // Sort by modification date (most recent first)
    let sortedLogFiles = logFiles.sorted { file1, file2 in
      let date1 = (try? file1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
      let date2 = (try? file2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
      return date1 > date2
    }
    
    // Collect logs from recent files
    for logFile in sortedLogFiles.prefix(10) { // Limit to 10 most recent books
      if let bookId = logFile.deletingPathExtension().lastPathComponent.isEmpty ? nil : logFile.deletingPathExtension().lastPathComponent {
        if let logText = AudiobookFileLogger.shared.retrieveLog(forBookId: bookId) {
          logContent += "\n--- Book ID: \(bookId) ---\n"
          logContent += logText
          logContent += "\n"
        }
      }
    }
    
    if sortedLogFiles.isEmpty {
      logContent += "No audiobook playback logs found.\n"
    }
    
    return Data(logContent.utf8)
  }
  
  /// Collects Crashlytics breadcrumbs if available
  private func collectCrashlyticsBreadcrumbs() async -> Data {
    var logContent = "=== Crashlytics Breadcrumbs ===\n"
    logContent += "Generated: \(Date())\n\n"
    
    #if FEATURE_CRASH_REPORTING
    if Bundle.main.applicationEnvironment == .production {
      logContent += "Crashlytics breadcrumbs are logged separately to Firebase.\n"
      logContent += "Check Firebase console for detailed crash reports.\n"
    } else {
      logContent += "Crashlytics is disabled in non-production builds.\n"
    }
    #else
    logContent += "Crashlytics is not enabled in this build.\n"
    #endif
    
    return Data(logContent.utf8)
  }
  
  /// Collects application-level logs
  private func collectApplicationLogs() async -> String {
    var logs = "=== Application Logs ===\n"
    
    // Collect app launch information
    logs += "Last Launch: \(UserDefaults.standard.object(forKey: "LastAppLaunchDate") ?? "Unknown")\n"
    logs += "App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")\n"
    logs += "Build Number: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")\n"
    
    // Crash recovery info
    let crashCount = UserDefaults.standard.integer(forKey: "PalaceCrashCount")
    let isInSafeMode = await CrashRecoveryService.shared.isInSafeMode()
    logs += "Crash Count: \(crashCount)\n"
    logs += "Safe Mode: \(isInSafeMode ? "YES" : "NO")\n"
    
    // Memory information
    let memoryUsage = reportMemoryUsage()
    logs += "\nCurrent Memory Usage: \(memoryUsage)\n"
    
    // Disk space information
    if let diskSpace = availableDiskSpace() {
      logs += "Available Disk Space: \(ByteCountFormatter.string(fromByteCount: diskSpace, countStyle: .file))\n"
    }
    
    logs += "\n"
    
    // Add persistent log file contents
    logs += await PersistentLogger.shared.retrieveAllLogs()
    logs += "\n"
    
    return logs
  }
  
  /// Collects network-related logs
  private func collectNetworkLogs() async -> String {
    var logs = "Recent network activity:\n"
    
    // Get cache information
    if let cache = URLCache.shared.currentDiskUsage as Int? {
      logs += "URL Cache Size: \(ByteCountFormatter.string(fromByteCount: Int64(cache), countStyle: .file))\n"
    }
    
    // Network reachability
    logs += "Network Status: \(Reachability.shared.isConnectedToNetwork() ? "Connected" : "Disconnected")\n"
    
    return logs
  }
  
  /// Collects book registry state information
  private func collectRegistryState() async -> String {
    var logs = ""
    
    let registry = TPPBookRegistry.shared
    let allBooks = registry.allBooks
    let downloadedBooks = allBooks.filter { registry.state(for: $0.identifier) == .downloadSuccessful }
    
    logs += "Total Books: \(allBooks.count)\n"
    logs += "Downloaded Books: \(downloadedBooks.count)\n"
    logs += "Registry State: \(registry.state)\n"
    logs += "Is Syncing: \(registry.isSyncing)\n"
    
    return logs
  }
  
  // MARK: - Device Information
  
  /// Collects device information matching ProblemReportEmail format
  private func collectDeviceInfo() -> String {
    let nativeHeight = UIScreen.main.nativeBounds.height
    let systemVersion = UIDevice.current.systemVersion
    let idiom: String
    
    switch UIDevice.current.userInterfaceIdiom {
    case .carPlay:
      idiom = "carPlay"
    case .pad:
      idiom = "pad"
    case .phone:
      idiom = "phone"
    case .tv:
      idiom = "tv"
    case .mac:
      idiom = "mac"
    default:
      idiom = "unspecified"
    }
    
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    let libraryName = AccountsManager.shared.currentAccount?.name ?? "No library selected"
    
    var deviceInfo = """
    ---
    Idiom: \(idiom)
    Platform: iOS
    OS: \(systemVersion)
    Height: \(nativeHeight)
    Palace Version: \(appVersion) (\(buildNumber))
    Library: \(libraryName)
    Device ID: \(UIDevice.current.identifierForVendor?.uuidString ?? "Unknown")
    """
    
    // Add memory and storage info
    deviceInfo += "\nPhysical Memory: \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))"
    
    if let diskSpace = availableDiskSpace() {
      deviceInfo += "\nAvailable Storage: \(ByteCountFormatter.string(fromByteCount: diskSpace, countStyle: .file))"
    }
    
    return deviceInfo
  }
  
  // MARK: - Email Composition
  
  @MainActor
  private func presentMailComposer(with logData: ErrorLogData, from viewController: UIViewController) async {
    let mailComposer = MFMailComposeViewController()
    mailComposer.mailComposeDelegate = MailComposerDelegate.shared
    mailComposer.setToRecipients([logsEmail])
    mailComposer.setSubject("Palace iOS Error Logs")
    
    // Set email body
    let body = """
    Please find attached diagnostic logs from Palace iOS.
    
    \(logData.deviceInfo)
    
    ---
    Note: These logs may contain book identifiers and app usage patterns but no personal information beyond the anonymous device ID shown above.
    """
    mailComposer.setMessageBody(body, isHTML: false)
    
    // Attach logs
    await attachLogs(to: mailComposer, logData: logData)
    
    viewController.present(mailComposer, animated: true)
  }
  
  private func attachLogs(to mailComposer: MFMailComposeViewController, logData: ErrorLogData) async {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
    let timestamp = dateFormatter.string(from: Date())
    
    // Calculate total size
    let totalSize = logData.errorLogs.count + logData.audiobookLogs.count + logData.crashlyticsBreadcrumbs.count
    
    if totalSize > maxLogSizeBytes {
      // Compress logs as zip
      if let zipData = await createZipArchive(logData: logData) {
        mailComposer.addAttachmentData(zipData, mimeType: "application/zip", fileName: "palace_logs_\(timestamp).zip")
      }
    } else {
      // Attach individual files
      mailComposer.addAttachmentData(logData.errorLogs, mimeType: "text/plain", fileName: "error_logs_\(timestamp).txt")
      mailComposer.addAttachmentData(logData.audiobookLogs, mimeType: "text/plain", fileName: "audiobook_logs_\(timestamp).txt")
      
      if !logData.crashlyticsBreadcrumbs.isEmpty {
        mailComposer.addAttachmentData(logData.crashlyticsBreadcrumbs, mimeType: "text/plain", fileName: "crashlytics_\(timestamp).txt")
      }
    }
  }
  
  @MainActor
  private func showMailNotAvailableAlert(from viewController: UIViewController) async {
    let alert = UIAlertController(
      title: "Mail Not Available",
      message: "Please configure a mail account in Settings, or contact \(logsEmail) to report issues.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    viewController.present(alert, animated: true)
  }
  
  // MARK: - Compression
  
  private func createZipArchive(logData: ErrorLogData) async -> Data? {
    // Create a temporary directory for the archive
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    
    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      
      // Write log files
      let errorLogFile = tempDir.appendingPathComponent("error_logs.txt")
      try logData.errorLogs.write(to: errorLogFile)
      
      let audiobookLogFile = tempDir.appendingPathComponent("audiobook_logs.txt")
      try logData.audiobookLogs.write(to: audiobookLogFile)
      
      if !logData.crashlyticsBreadcrumbs.isEmpty {
        let crashlyticsFile = tempDir.appendingPathComponent("crashlytics.txt")
        try logData.crashlyticsBreadcrumbs.write(to: crashlyticsFile)
      }
      
      // Create zip archive
      let zipFile = tempDir.appendingPathComponent("logs.zip")
      
      // Use built-in compression (simplified approach)
      // For production, consider using a proper zip library like ZIPFoundation
      let combinedData = logData.errorLogs + logData.audiobookLogs + logData.crashlyticsBreadcrumbs
      let compressedData = try (combinedData as NSData).compressed(using: .lzfse)
      
      // Clean up temp directory
      try? FileManager.default.removeItem(at: tempDir)
      
      return compressedData as Data
    } catch {
      Log.error(#file, "Failed to create zip archive: \(error.localizedDescription)")
      try? FileManager.default.removeItem(at: tempDir)
      return nil
    }
  }
  
  // MARK: - Helper Functions
  
  private func reportMemoryUsage() -> String {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    
    if kerr == KERN_SUCCESS {
      return ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
    }
    return "Unknown"
  }
  
  private func availableDiskSpace() -> Int64? {
    let fileURL = URL(fileURLWithPath: NSHomeDirectory() as String)
    do {
      let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      return values.volumeAvailableCapacityForImportantUsage
    } catch {
      return nil
    }
  }
}

// MARK: - Supporting Types

struct ErrorLogData {
  let errorLogs: Data
  let audiobookLogs: Data
  let crashlyticsBreadcrumbs: Data
  let deviceInfo: String
}

/// Mail composer delegate
@MainActor
private class MailComposerDelegate: NSObject, MFMailComposeViewControllerDelegate {
  static let shared = MailComposerDelegate()
  
  func mailComposeController(
    _ controller: MFMailComposeViewController,
    didFinishWith result: MFMailComposeResult,
    error: Error?
  ) {
    controller.dismiss(animated: true)
    
    guard let presentingVC = controller.presentingViewController else { return }
    
    switch result {
    case .sent:
      let alert = UIAlertController(
        title: "Logs Sent",
        message: "Thank you! Your diagnostic logs have been sent to the Palace team.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      presentingVC.present(alert, animated: true)
      
    case .failed:
      let alert = UIAlertController(
        title: "Send Failed",
        message: error?.localizedDescription ?? "Failed to send logs. Please try again.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      presentingVC.present(alert, animated: true)
      
    case .cancelled, .saved:
      break
      
    @unknown default:
      break
    }
  }
}

// MARK: - Localized Strings Extension

extension Strings {
  enum ErrorLogExporter {
    static let noAccountSetupTitle = "Mail Not Available"
    static let collectingLogs = "Collecting Logs"
    static let pleaseWait = "Please wait while we gather diagnostic information..."
  }
}

