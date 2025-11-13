//
//  RemoteFeatureFlags.swift
//  Palace
//
//  Created for Remote Feature Flag & Device-Specific Monitoring
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseRemoteConfig
import FirebaseAnalytics

/// Remote feature flags using Firebase Remote Config
/// Allows remote enabling of features for specific devices or all users
actor RemoteFeatureFlags {
  static let shared = RemoteFeatureFlags()
  
  private var remoteConfig: RemoteConfig
  private var lastFetchTime: Date?
  private let fetchInterval: TimeInterval = 3600 // 1 hour
  
  // MARK: - Feature Flag Keys
  
  enum FeatureFlag: String {
    case enhancedErrorLogging = "enhanced_error_logging_enabled"
    case enhancedErrorLoggingDeviceSpecific = "enhanced_error_logging_device_"
    case downloadRetryEnabled = "download_retry_enabled"
    case circuitBreakerEnabled = "circuit_breaker_enabled"
    
    var defaultValue: Bool {
      // All features disabled by default
      return false
    }
  }
  
  // MARK: - Initialization
  
  private init() {
    self.remoteConfig = RemoteConfig.remoteConfig()
    
    // Configure Remote Config
    let settings = RemoteConfigSettings()
    #if DEBUG
    // In DEBUG, fetch frequently for testing
    settings.minimumFetchInterval = 60 // 1 minute
    #else
    // In RELEASE, fetch hourly
    settings.minimumFetchInterval = 3600 // 1 hour
    #endif
    
    remoteConfig.configSettings = settings
    
    // Set default values
    setDefaultValues()
  }
  
  // MARK: - Setup
  
  /// Call this on app launch to fetch remote config
  func initialize() async {
    await fetchAndActivate()
  }
  
  private func setDefaultValues() {
    var defaults: [String: NSObject] = [:]
    
    // Feature flag defaults
    defaults[FeatureFlag.enhancedErrorLogging.rawValue] = NSNumber(value: false)
    defaults[FeatureFlag.downloadRetryEnabled.rawValue] = NSNumber(value: true)
    defaults[FeatureFlag.circuitBreakerEnabled.rawValue] = NSNumber(value: true)
    
    remoteConfig.setDefaults(defaults)
  }
  
  // MARK: - Fetching
  
  /// Fetch and activate remote config
  @discardableResult
  func fetchAndActivate() async -> Bool {
    do {
      let status = try await remoteConfig.fetchAndActivate()
      lastFetchTime = Date()
      
      switch status {
      case .successFetchedFromRemote:
        Log.info(#file, "✅ Remote config fetched and activated from server")
        return true
      case .successUsingPreFetchedData:
        Log.info(#file, "ℹ️ Using pre-fetched remote config data")
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
  
  /// Fetch if needed (respects fetch interval)
  func fetchIfNeeded() async {
    guard shouldFetch() else { return }
    await fetchAndActivate()
  }
  
  private func shouldFetch() -> Bool {
    guard let lastFetch = lastFetchTime else { return true }
    return Date().timeIntervalSince(lastFetch) > fetchInterval
  }
  
  // MARK: - Feature Flag Access
  
  /// Check if feature is enabled (with device-specific override)
  func isFeatureEnabled(_ feature: FeatureFlag) -> Bool {
    // Check device-specific flag first (highest priority)
    if let deviceSpecific = checkDeviceSpecificFlag(feature) {
      return deviceSpecific
    }
    
    // Check global flag
    let globalValue = remoteConfig.configValue(forKey: feature.rawValue).boolValue
    
    // Fallback to local setting if no remote value
    if remoteConfig.configValue(forKey: feature.rawValue).source == .default {
      return getLocalSetting(feature)
    }
    
    return globalValue
  }
  
  /// Check device-specific feature flag
  private func checkDeviceSpecificFlag(_ feature: FeatureFlag) -> Bool? {
    let deviceId = getDeviceIdentifier()
    // Sanitize UUID: remove hyphens for Firebase parameter compatibility
    let sanitizedDeviceId = deviceId.replacingOccurrences(of: "-", with: "")
    let deviceKey = feature.rawValue + "_device_" + sanitizedDeviceId
    
    let configValue = remoteConfig.configValue(forKey: deviceKey)
    if configValue.source == .remote {
      return configValue.boolValue
    }
    
    return nil // No device-specific override
  }
  
  /// Get device identifier for targeting
  private func getDeviceIdentifier() -> String {
    // Use UUID stored in UserDefaults for consistent device targeting
    let key = "TPPDeviceIdentifier"
    if let existingId = UserDefaults.standard.string(forKey: key) {
      return existingId
    }
    
    let newId = UUID().uuidString
    UserDefaults.standard.set(newId, forKey: key)
    return newId
  }
  
  /// Get local setting fallback
  private func getLocalSetting(_ feature: FeatureFlag) -> Bool {
    return feature.defaultValue
  }
  
  // MARK: - Device Info for Targeting
  
  /// Get device info for Firebase targeting
  func getDeviceInfo() -> [String: String] {
    var info: [String: String] = [:]
    
    info["device_id"] = getDeviceIdentifier()
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
  
  /// Set user properties for Firebase targeting
  func setUserPropertiesForTargeting() {
    let deviceInfo = getDeviceInfo()
    
    Analytics.setUserProperty(deviceInfo["device_id"], forName: "device_id")
    Analytics.setUserProperty(deviceInfo["device_model"], forName: "device_model")
    Analytics.setUserProperty(deviceInfo["ios_version"], forName: "ios_version")
    Analytics.setUserProperty(deviceInfo["build_type"], forName: "build_type")
    
    Log.info(#file, "✅ Firebase user properties set for remote targeting")
  }
}


