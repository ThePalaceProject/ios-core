//
//  FirebaseManager.swift
//  Palace
//
//  Centralized Firebase management to prevent race conditions.
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseRemoteConfig
import FirebaseAnalytics
import FirebaseCrashlytics

/// Centralized manager for all Firebase services.
/// This singleton ensures thread-safe access to Firebase resources and prevents
/// the "recursive_mutex lock failed" crash caused by multiple actors racing
/// to configure the shared RemoteConfig instance.
final class FirebaseManager {
  static let shared = FirebaseManager()
  
  // MARK: - Configuration
  
  private enum Configuration {
    static let minimumFetchIntervalDebug: TimeInterval = 60 // 1 minute
    static let minimumFetchIntervalRelease: TimeInterval = 3600 // 1 hour
    static let deviceIdentifierKey = "TPPDeviceIdentifier"
  }
  
  // MARK: - State
  
  private let remoteConfig: RemoteConfig
  private let lock = NSLock()
  private var isConfigured = false
  private var lastFetchTime: Date?
  private var cachedDeviceID: String?
  
  // MARK: - Remote Config Keys
  
  enum RemoteConfigKey: String {
    case enhancedErrorLoggingEnabled = "enhanced_error_logging_enabled"
    case enhancedErrorLoggingDevicePrefix = "enhanced_error_logging_device_"
    case downloadRetryEnabled = "download_retry_enabled"
    case circuitBreakerEnabled = "circuit_breaker_enabled"
  }
  
  // MARK: - Initialization
  
  private init() {
    // Get the shared RemoteConfig instance once
    self.remoteConfig = RemoteConfig.remoteConfig()
    
    // Configure settings immediately in init to prevent races
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
  
  // MARK: - Device Identifier
  
  /// Returns a consistent device identifier for targeting.
  /// Thread-safe and cached for performance.
  var deviceID: String {
    lock.lock()
    defer { lock.unlock() }
    
    if let cached = cachedDeviceID {
      return cached
    }
    
    if let existing = UserDefaults.standard.string(forKey: Configuration.deviceIdentifierKey) {
      cachedDeviceID = existing
      return existing
    }
    
    let newID = UUID().uuidString
    UserDefaults.standard.set(newID, forKey: Configuration.deviceIdentifierKey)
    cachedDeviceID = newID
    Log.info(#file, "Generated new device ID: \(newID)")
    return newID
  }
  
  /// Sanitized device ID for Firebase parameter compatibility (no hyphens).
  var sanitizedDeviceID: String {
    deviceID.replacingOccurrences(of: "-", with: "")
  }
  
  // MARK: - Remote Config Access
  
  /// Fetches and activates remote config. Thread-safe.
  /// - Returns: True if fetch/activate succeeded.
  @discardableResult
  func fetchAndActivateRemoteConfig() async -> Bool {
    lock.lock()
    defer { lock.unlock() }
    
    do {
      let status = try await remoteConfig.fetchAndActivate()
      lastFetchTime = Date()
      
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
  
  /// Fetches remote config if the minimum interval has passed.
  func fetchIfNeeded() async {
    let shouldFetch: Bool = {
      lock.lock()
      defer { lock.unlock() }
      
      guard let lastFetch = lastFetchTime else { return true }
      
      #if DEBUG
      let interval = Configuration.minimumFetchIntervalDebug
      #else
      let interval = Configuration.minimumFetchIntervalRelease
      #endif
      
      return Date().timeIntervalSince(lastFetch) > interval
    }()
    
    if shouldFetch {
      await fetchAndActivateRemoteConfig()
    }
  }
  
  /// Gets a boolean value from remote config. Thread-safe.
  func getBoolValue(forKey key: RemoteConfigKey) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return remoteConfig.configValue(forKey: key.rawValue).boolValue
  }
  
  /// Gets a boolean value from remote config with device-specific override. Thread-safe.
  func getBoolValue(forKey key: RemoteConfigKey, checkingDeviceSpecific: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    
    if checkingDeviceSpecific {
      // Check device-specific flag first
      let deviceKey = key.rawValue + "_device_" + sanitizedDeviceID
      let deviceValue = remoteConfig.configValue(forKey: deviceKey)
      
      if deviceValue.source == .remote {
        return deviceValue.boolValue
      }
    }
    
    // Fall back to global value
    return remoteConfig.configValue(forKey: key.rawValue).boolValue
  }
  
  /// Checks if a config value came from the remote server.
  func isRemoteValue(forKey key: RemoteConfigKey) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return remoteConfig.configValue(forKey: key.rawValue).source == .remote
  }
  
  // MARK: - Enhanced Logging
  
  /// Checks if enhanced error logging is enabled for this device.
  func isEnhancedLoggingEnabled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    
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
    
    // Default: disabled
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
    // Add enhanced logging metadata if enabled
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
    
    // Log to Crashlytics as well
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
  
  /// Call this when the app enters the background to pause Firebase operations.
  func applicationDidEnterBackground() {
    Log.info(#file, "Firebase: App entering background, pausing operations")
  }
  
  /// Call this when the app becomes active to resume Firebase operations.
  func applicationDidBecomeActive() {
    Log.info(#file, "Firebase: App became active")
    
    // Refresh remote config in background
    Task {
      await fetchIfNeeded()
    }
  }
}
