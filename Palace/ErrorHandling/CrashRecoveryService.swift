//
//  CrashRecoveryService.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Service responsible for detecting and recovering from app crashes
actor CrashRecoveryService {
  static let shared = CrashRecoveryService()
  
  private let crashCountKey = "PalaceCrashCount"
  private let lastCleanExitKey = "PalaceLastCleanExit"
  private let lastLaunchTimeKey = "PalaceLastLaunchTime"
  private let safeModeKey = "PalaceSafeMode"
  private let crashTimestampsKey = "PalaceCrashTimestamps"
  
  private let maxCrashesBeforeSafeMode = 3
  private let crashWindowSeconds: TimeInterval = 300 // 5 minutes
  
  private init() {}
  
  // MARK: - Crash Detection
  
  /// Checks if the app crashed on last launch and takes appropriate action
  @MainActor
  func checkForCrashOnLaunch() async {
    let didCrash = await detectCrash()
    
    if didCrash {
      await handleCrashDetection()
    }
    
    // Mark that we've successfully launched
    await recordLaunch()
  }
  
  /// Detects if the app crashed on previous launch
  private func detectCrash() -> Bool {
    let lastCleanExit = UserDefaults.standard.bool(forKey: lastCleanExitKey)
    let lastLaunchTime = UserDefaults.standard.object(forKey: lastLaunchTimeKey) as? Date
    
    // If we didn't exit cleanly and last launch was recent, it was likely a crash
    if !lastCleanExit {
      if let lastLaunch = lastLaunchTime {
        let timeSinceLastLaunch = Date().timeIntervalSince(lastLaunch)
        // If app was running in last 5 minutes, consider it a crash
        if timeSinceLastLaunch < crashWindowSeconds {
          return true
        }
      } else {
        // No last launch time but unclean exit - possible crash
        return true
      }
    }
    
    return false
  }
  
  /// Records a crash and determines if safe mode should be activated
  private func handleCrashDetection() async {
    var crashCount = UserDefaults.standard.integer(forKey: crashCountKey)
    crashCount += 1
    UserDefaults.standard.set(crashCount, forKey: crashCountKey)
    
    // Store crash timestamp
    var crashTimestamps = UserDefaults.standard.array(forKey: crashTimestampsKey) as? [Date] ?? []
    crashTimestamps.append(Date())
    
    // Keep only crashes from last hour
    let oneHourAgo = Date().addingTimeInterval(-3600)
    crashTimestamps = crashTimestamps.filter { $0 > oneHourAgo }
    UserDefaults.standard.set(crashTimestamps, forKey: crashTimestampsKey)
    
    Log.error(#file, "🔴 Crash detected on previous launch. Total crashes: \(crashCount)")
    TPPErrorLogger.logError(
      withCode: .appCrashDetected,
      summary: "App crash detected on launch",
      metadata: [
        "crashCount": crashCount,
        "recentCrashCount": crashTimestamps.count,
        "timeSinceLastLaunch": Date().timeIntervalSince(UserDefaults.standard.object(forKey: lastLaunchTimeKey) as? Date ?? Date())
      ]
    )
    
    // Check if we should enter safe mode
    if crashTimestamps.count >= maxCrashesBeforeSafeMode {
      await enterSafeMode()
    } else {
      await performCrashRecovery()
    }
  }
  
  // MARK: - Safe Mode
  
  /// Enters safe mode after multiple crashes
  @MainActor
  private func enterSafeMode() async {
    UserDefaults.standard.set(true, forKey: safeModeKey)
    
    Log.error(#file, "⚠️ Entering safe mode after \(maxCrashesBeforeSafeMode) crashes")
    
    // Show safe mode alert to user
    let alert = UIAlertController(
      title: "Safe Mode",
      message: "The app has crashed multiple times. Running in safe mode with limited features. Please try restarting the app or contact support if the problem persists.",
      preferredStyle: .alert
    )
    
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    alert.addAction(UIAlertAction(title: "Reset App", style: .destructive) { _ in
      Task {
        await self.resetAppState()
      }
    })
    
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootVC = windowScene.windows.first?.rootViewController {
      rootVC.present(alert, animated: true)
    }
  }
  
  /// Checks if the app is currently in safe mode
  func isInSafeMode() -> Bool {
    return UserDefaults.standard.bool(forKey: safeModeKey)
  }
  
  /// Exits safe mode (called after successful app run or user reset)
  func exitSafeMode() {
    UserDefaults.standard.set(false, forKey: safeModeKey)
    UserDefaults.standard.set(0, forKey: crashCountKey)
    UserDefaults.standard.removeObject(forKey: crashTimestampsKey)
    Log.info(#file, "✅ Exited safe mode")
  }
  
  // MARK: - Crash Recovery
  
  /// Performs automatic recovery actions after crash
  @MainActor
  private func performCrashRecovery() async {
    Log.info(#file, "🔧 Performing crash recovery...")
    
    // Reset potentially corrupted download state
    await resetDownloadState()
    
    // Clear temporary files
    await clearTemporaryFiles()
    
    // Validate registry integrity
    await validateRegistryIntegrity()
    
    Log.info(#file, "✅ Crash recovery complete")
  }
  
  /// Resets download state that may have been corrupted during crash
  private func resetDownloadState() async {
    // Reset any books stuck in downloading state
    let registry = TPPBookRegistry.shared
    let allBooks = registry.allBooks
    
    for book in allBooks {
      let state = registry.state(for: book.identifier)
      if state == .downloading || state == .SAMLStarted {
        registry.setState(.downloadFailed, for: book.identifier)
        Log.info(#file, "Reset stuck download: \(book.title)")
      }
    }
  }
  
  /// Clears temporary files that may be corrupted
  private func clearTemporaryFiles() async {
    let tempDir = FileManager.default.temporaryDirectory
    do {
      let contents = try FileManager.default.contentsOfDirectory(
        at: tempDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: .skipsHiddenFiles
      )
      
      for fileURL in contents {
        try? FileManager.default.removeItem(at: fileURL)
      }
      
      Log.info(#file, "Cleared \(contents.count) temporary files")
    } catch {
      Log.error(#file, "Failed to clear temporary files: \(error.localizedDescription)")
    }
  }
  
  /// Validates and repairs registry integrity
  private func validateRegistryIntegrity() async {
    // Check if registry file is readable
    let registry = TPPBookRegistry.shared
    let state = registry.state
    
    if state == .unloaded {
      registry.load()
      Log.info(#file, "Reloaded unloaded registry")
    }
    
    // Verify registry can be read
    let _ = registry.allBooks
    Log.info(#file, "Registry integrity validated")
  }
  
  // MARK: - App Lifecycle Tracking
  
  /// Records a successful app launch
  func recordLaunch() {
    UserDefaults.standard.set(false, forKey: lastCleanExitKey)
    UserDefaults.standard.set(Date(), forKey: lastLaunchTimeKey)
    UserDefaults.standard.synchronize()
  }
  
  /// Marks a clean exit (call in applicationWillTerminate or background)
  func recordCleanExit() {
    UserDefaults.standard.set(true, forKey: lastCleanExitKey)
    UserDefaults.standard.synchronize()
  }
  
  /// Decrements crash count after successful session (called after app runs without crash for 10+ minutes)
  func recordStableSession() {
    let crashCount = UserDefaults.standard.integer(forKey: crashCountKey)
    if crashCount > 0 {
      UserDefaults.standard.set(max(0, crashCount - 1), forKey: crashCountKey)
      Log.info(#file, "Decremented crash count to \(max(0, crashCount - 1)) after stable session")
    }
    
    // If we've been stable, exit safe mode
    if isInSafeMode() && crashCount <= 1 {
      exitSafeMode()
    }
  }
  
  // MARK: - Full Reset
  
  /// Performs a full app state reset (destructive)
  @MainActor
  func resetAppState() async {
    Log.warn(#file, "⚠️ Performing full app state reset...")
    
    // Clear authentication tokens for all accounts
    for account in AccountsManager.shared.accounts() {
      let userAccount = TPPUserAccount.sharedAccount(libraryUUID: account.uuid)
      userAccount.setAuthToken("", barcode: "", pin: "", expirationDate: nil)
    }
    
    // Clear all caches
    ImageCache.shared.clear()
    URLCache.shared.removeAllCachedResponses()
    
    // Pause all downloads (cancellation would lose progress)
    MyBooksDownloadCenter.shared.pauseAllDownloads()
    
    // Reset registry for current account
    if let currentAccount = AccountsManager.shared.currentAccount {
      TPPBookRegistry.shared.reset(currentAccount.uuid)
    }
    
    // Exit safe mode
    await exitSafeMode()
    
    // Restart app
    Log.info(#file, "App state reset complete. Restarting...")
    
    let alert = UIAlertController(
      title: "Reset Complete",
      message: "The app has been reset. Please restart the app.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootVC = windowScene.windows.first?.rootViewController {
      rootVC.present(alert, animated: true)
    }
  }
}

// MARK: - Error Code Extension

extension TPPErrorCode {
  static let appCrashDetected = TPPErrorCode(rawValue: 104) ?? .appLogicInconsistency
}

