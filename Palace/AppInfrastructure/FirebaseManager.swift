//
//  FirebaseManager.swift
//  Palace
//
//  Centralized Firebase management.
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import os
import FirebaseCore
import FirebaseRemoteConfig
import FirebaseAnalytics
import FirebaseCrashlytics

/// Centralized manager for all Firebase services.
/// 
/// Thread Safety:
/// - Device IDs are immutable `let` properties computed once at init
/// - RemoteConfig is thread-safe internally (no external locking needed)
/// - lastFetchTime is advisory only; RemoteConfig handles its own rate limiting
final class FirebaseManager {
  static let shared = FirebaseManager()
  
  // MARK: - Configuration
  
  private enum Configuration {
    static let minimumFetchIntervalDebug: TimeInterval = 60 // 1 minute
    static let minimumFetchIntervalRelease: TimeInterval = 3600 // 1 hour
    static let deviceIdentifierKey = "TPPDeviceIdentifier"
  }
  
  // MARK: - Immutable State (thread-safe by design)
  
  /// Unique device identifier, persisted across app launches
  let deviceID: String
  
  /// Device ID without hyphens for Firebase parameter compatibility
  let sanitizedDeviceID: String
  
  // MARK: - Firebase Services
  
  private let remoteConfig: RemoteConfig
  
  /// Atomic flag to prevent concurrent fetch operations
  private let isFetching = OSAllocatedUnfairLock(initialState: false)
  
  // MARK: - Remote Config Keys
  
  enum RemoteConfigKey: String {
    case enhancedErrorLoggingEnabled = "enhanced_error_logging_enabled"
    case enhancedErrorLoggingDevicePrefix = "enhanced_error_logging_device_"
    case downloadRetryEnabled = "download_retry_enabled"
    case circuitBreakerEnabled = "circuit_breaker_enabled"
  }
  
  // MARK: - Initialization
  
  private init() {
    // Compute device ID once - it never changes after creation
    if let existing = UserDefaults.standard.string(forKey: Configuration.deviceIdentifierKey) {
      self.deviceID = existing
    } else {
      let newID = UUID().uuidString
      UserDefaults.standard.set(newID, forKey: Configuration.deviceIdentifierKey)
      self.deviceID = newID
      Log.info(#file, "Generated new device ID: \(newID)")
    }
    self.sanitizedDeviceID = deviceID.replacingOccurrences(of: "-", with: "")
    
    // Get the shared RemoteConfig instance
    self.remoteConfig = RemoteConfig.remoteConfig()
    
    // Configure settings
    configureRemoteConfigSettings()
    setDefaultValues()
  }
  
  private func configureRemoteConfigSettings() {
    let settings = RemoteConfigSettings()
    
    #if DEBUG
    settings.minimumFetchInterval = Configuration.minimumFetchIntervalDebug
    #else
    settings.minimumFetchInterval = Configuration.minimumFetchIntervalRelease
    #endif
    
    remoteConfig.configSettings = settings
  }
  
  private func setDefaultValues() {
    remoteConfig.setDefaults([
      RemoteConfigKey.enhancedErrorLoggingEnabled.rawValue: NSNumber(value: false),
      RemoteConfigKey.downloadRetryEnabled.rawValue: NSNumber(value: true),
      RemoteConfigKey.circuitBreakerEnabled.rawValue: NSNumber(value: true)
    ])
  }
  
  // MARK: - Remote Config Access
  
  /// Fetches and activates remote config.
  /// Uses atomic flag to prevent concurrent fetches (which could trigger Firebase mutex issues).
  @discardableResult
  func fetchAndActivateRemoteConfig() async -> Bool {
    // Atomically check and set fetching flag - if already fetching, skip
    let alreadyFetching = isFetching.withLock { fetching -> Bool in
      if fetching { return true }
      fetching = true
      return false
    }
    
    guard !alreadyFetching else {
      Log.info(#file, "Remote config fetch already in progress, skipping")
      return false
    }
    
    defer {
      isFetching.withLock { $0 = false }
    }
    
    do {
      let status = try await remoteConfig.fetchAndActivate()
      
      switch status {
      case .successFetchedFromRemote:
        Log.info(#file, "✅ Remote config fetched from server")
        return true
      case .successUsingPreFetchedData:
        Log.info(#file, "ℹ️ Using pre-fetched remote config")
        return true
      case .error:
        Log.error(#file, "❌ Error activating remote config")
        return false
      @unknown default:
        return false
      }
    } catch {
      Log.error(#file, "Failed to fetch remote config: \(error.localizedDescription)")
      return false
    }
  }
  
  /// Gets a boolean value from remote config.
  func getBoolValue(forKey key: RemoteConfigKey) -> Bool {
    remoteConfig.configValue(forKey: key.rawValue).boolValue
  }
  
  /// Gets a boolean value with device-specific override check.
  func getBoolValue(forKey key: RemoteConfigKey, checkingDeviceSpecific: Bool) -> Bool {
    if checkingDeviceSpecific {
      let deviceKey = key.rawValue + "_device_" + sanitizedDeviceID
      let deviceValue = remoteConfig.configValue(forKey: deviceKey)
      
      if deviceValue.source == .remote {
        return deviceValue.boolValue
      }
    }
    
    return remoteConfig.configValue(forKey: key.rawValue).boolValue
  }
  
  /// Checks if a config value came from the remote server.
  func isRemoteValue(forKey key: RemoteConfigKey) -> Bool {
    remoteConfig.configValue(forKey: key.rawValue).source == .remote
  }
  
  // MARK: - Enhanced Logging
  
  /// Checks if enhanced error logging is enabled for this device.
  func isEnhancedLoggingEnabled() -> Bool {
    // Check device-specific flag first
    let deviceKey = RemoteConfigKey.enhancedErrorLoggingDevicePrefix.rawValue + sanitizedDeviceID
    let deviceValue = remoteConfig.configValue(forKey: deviceKey)
    
    if deviceValue.source == .remote {
      return deviceValue.boolValue
    }
    
    // Check global flag
    let globalValue = remoteConfig.configValue(forKey: RemoteConfigKey.enhancedErrorLoggingEnabled.rawValue)
    if globalValue.source == .remote {
      return globalValue.boolValue
    }
    
    return false
  }
  
  // MARK: - Analytics User Properties
  
  /// Sets user properties for Firebase Analytics targeting.
  func setUserPropertiesForTargeting() {
    let deviceInfo = getDeviceInfo()
    
    Analytics.setUserProperty(deviceInfo["device_id"], forName: "device_id")
    Analytics.setUserProperty(deviceInfo["device_model"], forName: "device_model")
    Analytics.setUserProperty(deviceInfo["ios_version"], forName: "ios_version")
    Analytics.setUserProperty(deviceInfo["build_type"], forName: "build_type")
    
    Log.info(#file, "✅ Firebase user properties set for targeting")
  }
  
  /// Returns device information dictionary for targeting and logging.
  func getDeviceInfo() -> [String: String] {
    var info: [String: String] = [:]
    
    info["device_id"] = deviceID
    info["device_model"] = UIDevice.current.model
    info["ios_version"] = UIDevice.current.systemVersion
    info["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    info["build_number"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    
    #if DEBUG
    info["build_type"] = "debug"
    #else
    info["build_type"] = "release"
    #endif
    
    if let accountId = AccountsManager.shared.currentAccountId {
      info["library_id"] = accountId
    }
    
    return info
  }
  
  // MARK: - Crashlytics
  
  /// Configures Crashlytics with device-specific information.
  func configureCrashlytics() {
    guard Bundle.main.applicationEnvironment == .production else { return }
    
    #if FEATURE_CRASH_REPORTING
    Crashlytics.crashlytics().setCustomValue(deviceID, forKey: "PalaceDeviceID")
    
    if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
      Crashlytics.crashlytics().setCustomValue(vendorID, forKey: "VendorDeviceID")
    }
    #endif
  }
  
  /// Sets the user ID for Crashlytics (hashed for privacy).
  func setCrashlyticsUserID(_ userID: String?) {
    guard Bundle.main.applicationEnvironment == .production else { return }
    
    #if FEATURE_CRASH_REPORTING
    if let userIDmd5 = userID?.md5hex() {
      Crashlytics.crashlytics().setUserID(userIDmd5)
    } else {
      Crashlytics.crashlytics().setUserID("SIGNED_OUT_USER")
    }
    #endif
  }
  
  /// Logs an error to Crashlytics with enhanced metadata if enabled.
  func logError(_ error: NSError) {
    guard Bundle.main.applicationEnvironment == .production else {
      Log.error("LOG_ERROR", "\(error)")
      return
    }
    
    #if FEATURE_CRASH_REPORTING
    if isEnhancedLoggingEnabled() {
      Crashlytics.crashlytics().setCustomValue(true, forKey: "enhanced_logging_enabled")
      Crashlytics.crashlytics().setCustomValue(deviceID, forKey: "device_id")
      Crashlytics.crashlytics().log("Context: \(error.domain)")
    }
    
    Crashlytics.crashlytics().record(error: error)
    #else
    Log.error("LOG_ERROR", "\(error)")
    #endif
  }
  
  /// Logs a breadcrumb message to Crashlytics.
  func logBreadcrumb(_ message: String) {
    guard Bundle.main.applicationEnvironment == .production else { return }
    
    #if FEATURE_CRASH_REPORTING
    Crashlytics.crashlytics().log(message)
    #endif
  }
  
  // MARK: - Analytics Events
  
  /// Logs an enhanced error event to Analytics.
  func logEnhancedErrorEvent(
    error: Error,
    context: String,
    metadata: [String: Any] = [:]
  ) {
    guard isEnhancedLoggingEnabled() else { return }
    
    let params: [String: Any] = [
      "error_domain": (error as NSError).domain,
      "error_code": (error as NSError).code,
      "context": context,
      "device_id": deviceID
    ]
    
    Analytics.logEvent("enhanced_error_logged", parameters: params)
    
    #if FEATURE_CRASH_REPORTING
    let stackTrace = Thread.callStackSymbols.joined(separator: "\n")
    Crashlytics.crashlytics().log("Enhanced Error: \(context)")
    Crashlytics.crashlytics().log("Error: \(error.localizedDescription)")
    Crashlytics.crashlytics().log("Stack Trace:\n\(stackTrace)")
    
    for (key, value) in metadata {
      Crashlytics.crashlytics().log("\(key): \(value)")
    }
    #endif
    
    Log.info(#file, "📊 Enhanced error data sent to Firebase")
  }
  
  // MARK: - Lifecycle
  
  /// Called when the app enters background.
  func applicationDidEnterBackground() {
    Log.info(#file, "Firebase: App entering background")
  }
  
  /// Called when the app becomes active.
  func applicationDidBecomeActive() {
    Log.info(#file, "Firebase: App became active")
    
    // RemoteConfig handles its own rate limiting via minimumFetchInterval
    Task {
      await fetchAndActivateRemoteConfig()
    }
  }
}
