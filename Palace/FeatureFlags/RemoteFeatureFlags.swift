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
    
    var defaultValue: Bool {
      switch self {
      case .downloadRetryEnabled, .circuitBreakerEnabled:
        return true
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
