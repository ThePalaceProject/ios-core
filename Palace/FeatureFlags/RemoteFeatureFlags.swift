//
//  RemoteFeatureFlags.swift
//  Palace
//
//  Created for Remote Feature Flag & Device-Specific Monitoring
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseAnalytics

/// Remote feature flags using Firebase Remote Config.
/// 
/// NOTE: This class delegates all Firebase RemoteConfig access to FirebaseManager
/// to prevent race conditions that cause the "recursive_mutex lock failed" crash.
/// Do NOT access RemoteConfig directly from this class.
final class RemoteFeatureFlags {
  static let shared = RemoteFeatureFlags()
  
  private var lastFetchTime: Date?
  private let fetchInterval: TimeInterval = 3600 // 1 hour
  private let lock = NSLock()
  
  // MARK: - Feature Flag Keys
  
  enum FeatureFlag: String {
    case enhancedErrorLogging = "enhanced_error_logging_enabled"
    case enhancedErrorLoggingDeviceSpecific = "enhanced_error_logging_device_"
    case downloadRetryEnabled = "download_retry_enabled"
    case circuitBreakerEnabled = "circuit_breaker_enabled"
    case carPlayEnabled = "carplay_enabled"
    
    var defaultValue: Bool {
      switch self {
      case .downloadRetryEnabled, .circuitBreakerEnabled:
        return true
      case .carPlayEnabled:
        // CarPlay defaults to disabled - enable via Firebase Remote Config when ready for production
        return false
      default:
        return false
      }
    }
    
    /// Converts to FirebaseManager key if available.
    var managerKey: FirebaseManager.RemoteConfigKey? {
      switch self {
      case .enhancedErrorLogging:
        return .enhancedErrorLoggingEnabled
      case .downloadRetryEnabled:
        return .downloadRetryEnabled
      case .circuitBreakerEnabled:
        return .circuitBreakerEnabled
      case .carPlayEnabled:
        return .carPlayEnabled
      default:
        return nil
      }
    }
  }
  
  // MARK: - Initialization
  
  private init() {}
  
  // MARK: - Setup
  
  /// Call this on app launch to fetch remote config.
  func initialize() async {
    await fetchAndActivate()
  }
  
  // MARK: - Fetching
  
  /// Fetch and activate remote config.
  @discardableResult
  func fetchAndActivate() async -> Bool {
    let success = await FirebaseManager.shared.fetchAndActivateRemoteConfig()
    
    lock.lock()
      lastFetchTime = Date()
    lock.unlock()
    
    return success
  }
  
  /// Fetch if needed (respects fetch interval).
  func fetchIfNeeded() async {
    guard shouldFetch() else { return }
    await fetchAndActivate()
  }
  
  private func shouldFetch() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    
    guard let lastFetch = lastFetchTime else { return true }
    return Date().timeIntervalSince(lastFetch) > fetchInterval
  }
  
  // MARK: - Feature Flag Access
  
  /// Check if feature is enabled (with device-specific override).
  func isFeatureEnabled(_ feature: FeatureFlag) -> Bool {
    // Delegate to FirebaseManager for thread-safe access
    if let managerKey = feature.managerKey {
      return FirebaseManager.shared.getBoolValue(
        forKey: managerKey,
        checkingDeviceSpecific: feature == .enhancedErrorLogging
      )
    }
    
    // For device-specific flags, check via FirebaseManager
    if feature == .enhancedErrorLogging {
      return FirebaseManager.shared.isEnhancedLoggingEnabled()
    }
    
    // Fallback to default
    return feature.defaultValue
  }
  
  // MARK: - Convenience Properties
  
  /// UserDefaults key for cached CarPlay feature flag.
  private static let carPlayEnabledCacheKey = "RemoteFeatureFlags.carPlayEnabled"
  
  /// Whether CarPlay support is enabled.
  /// 
  /// Controlled by the `CARPLAY_ENABLED` Swift compiler flag.
  /// To enable CarPlay in a build:
  /// 1. Add `-DCARPLAY_ENABLED` to "Other Swift Flags" in Build Settings
  /// 2. Or create a separate scheme/configuration with this flag
  ///
  /// When CARPLAY_ENABLED is set, uses Firebase Remote Config for runtime control.
  /// When not set, CarPlay is completely disabled at compile time.
  var isCarPlayEnabled: Bool {
    #if CARPLAY_ENABLED
    // CarPlay compiled in - check Firebase flag for runtime control
    let remoteValue = isFeatureEnabled(.carPlayEnabled)
    let previousCached: Bool? = UserDefaults.standard.object(forKey: Self.carPlayEnabledCacheKey) != nil
      ? UserDefaults.standard.bool(forKey: Self.carPlayEnabledCacheKey)
      : nil
    UserDefaults.standard.set(remoteValue, forKey: Self.carPlayEnabledCacheKey)
    
    if let prev = previousCached, prev != remoteValue {
      Log.info(#file, "🚗 CarPlay feature flag changed: \(prev) → \(remoteValue)")
    }
    
    return remoteValue
    #else
    // CarPlay not compiled in
    return false
    #endif
  }
  
  /// Cached CarPlay enabled value for use during early app lifecycle
  /// (before Remote Config is fetched). Returns the last known value.
  ///
  /// Controlled by the `CARPLAY_ENABLED` Swift compiler flag.
  var isCarPlayEnabledCached: Bool {
    #if CARPLAY_ENABLED
    // CarPlay compiled in - check cached Firebase flag
    if UserDefaults.standard.object(forKey: Self.carPlayEnabledCacheKey) != nil {
      let cached = UserDefaults.standard.bool(forKey: Self.carPlayEnabledCacheKey)
      Log.debug(#file, "🚗 CarPlay feature flag (cached): \(cached)")
      return cached
    }
    // No cached value - return default
    Log.debug(#file, "🚗 CarPlay feature flag (no cache, using default): \(FeatureFlag.carPlayEnabled.defaultValue)")
    return FeatureFlag.carPlayEnabled.defaultValue
    #else
    // CarPlay not compiled in
    return false
    #endif
  }
  
  // MARK: - Device Info for Targeting
  
  /// Get device info for Firebase targeting.
  func getDeviceInfo() -> [String: String] {
    FirebaseManager.shared.getDeviceInfo()
  }
  
  /// Set user properties for Firebase targeting.
  func setUserPropertiesForTargeting() {
    FirebaseManager.shared.setUserPropertiesForTargeting()
  }
}
