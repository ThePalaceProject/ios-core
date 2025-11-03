//
//  DeviceSpecificErrorMonitor.swift
//  Palace
//
//  Created for Remote Device-Specific Error Logging
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseRemoteConfig
import FirebaseAnalytics
import FirebaseCrashlytics

/// Lightweight error monitor that can be remotely enabled for specific devices
/// Zero overhead when disabled, comprehensive logging when enabled
actor DeviceSpecificErrorMonitor {
  static let shared = DeviceSpecificErrorMonitor()
  
  private var remoteConfig: RemoteConfig
  private var isInitialized = false
  
  private init() {
    self.remoteConfig = RemoteConfig.remoteConfig()
    
    // Configure Remote Config
    let settings = RemoteConfigSettings()
    #if DEBUG
    settings.minimumFetchInterval = 60 // 1 minute in DEBUG
    #else
    settings.minimumFetchInterval = 3600 // 1 hour in RELEASE
    #endif
    
    remoteConfig.configSettings = settings
    setDefaultValues()
  }
  
  // MARK: - Initialization
  
  func initialize() async {
    guard !isInitialized else { return }
    
    do {
      let status = try await remoteConfig.fetchAndActivate()
      isInitialized = true
      
      switch status {
      case .successFetchedFromRemote:
        Log.info(#file, "✅ Error monitoring remote config fetched")
      case .successUsingPreFetchedData:
        Log.info(#file, "ℹ️ Using cached error monitoring config")
      case .error:
        Log.error(#file, "❌ Failed to fetch error monitoring config")
      @unknown default:
        break
      }
    } catch {
      Log.error(#file, "Error fetching remote config: \(error.localizedDescription)")
    }
  }
  
  private func setDefaultValues() {
    remoteConfig.setDefaults([
      "enhanced_error_logging_enabled": NSNumber(value: false)
    ])
  }
  
  // MARK: - Device ID
  
  nonisolated func getDeviceID() -> String {
    // Use same key as RemoteFeatureFlags to ensure consistency
    let key = "TPPDeviceIdentifier"
    if let existingID = UserDefaults.standard.string(forKey: key) {
      return existingID
    }
    
    let newID = UUID().uuidString
    UserDefaults.standard.set(newID, forKey: key)
    Log.info(#file, "Generated new device ID: \(newID)")
    return newID
  }
  
  // MARK: - Check if Enabled
  
  func isEnhancedLoggingEnabled() -> Bool {
    // Check device-specific flag first (highest priority)
    let deviceID = getDeviceID()
    let sanitizedDeviceID = deviceID.replacingOccurrences(of: "-", with: "")
    let deviceKey = "enhanced_error_logging_device_\(sanitizedDeviceID)"
    
    Log.debug(#file, "Checking enhanced logging: device_id=\(deviceID), key=\(deviceKey)")
    
    let deviceConfigValue = remoteConfig.configValue(forKey: deviceKey)
    if deviceConfigValue.source == .remote {
      Log.info(#file, "✅ Enhanced logging enabled via device-specific flag: \(deviceConfigValue.boolValue)")
      return deviceConfigValue.boolValue
    }
    
    // Check global flag
    let globalValue = remoteConfig.configValue(forKey: "enhanced_error_logging_enabled")
    if globalValue.source == .remote {
      Log.info(#file, "Enhanced logging from global flag: \(globalValue.boolValue)")
      return globalValue.boolValue
    }
    
    // Default: disabled
    Log.debug(#file, "Enhanced logging disabled (no remote config)")
    return false
  }
  
  // MARK: - Enhanced Error Logging
  
  /// Log error with full stack trace and context when enabled
  /// NOTE: This should NOT call TPPErrorLogger to avoid infinite recursion
  func logError(
    _ error: Error,
    context: String,
    metadata: [String: Any] = [:]
  ) {
    let isEnabled = isEnhancedLoggingEnabled()
    Log.info(#file, "🔍 logError called - Enhanced: \(isEnabled), context: \(context)")
    
    guard isEnabled else {
      // Enhanced not enabled, nothing to do (TPPErrorLogger already handles normal logging)
      return
    }
    
    Log.info(#file, "📊 ENHANCED logging active - capturing full stack trace")
    
    // Enhanced logging: Send to Firebase Analytics with stack trace
    let analyticsParams: [String: Any] = [
      "error_domain": (error as NSError).domain,
      "error_code": (error as NSError).code,
      "context": context,
      "device_id": getDeviceID()
    ]
    
    Analytics.logEvent("enhanced_error_logged", parameters: analyticsParams)
    
    // Log to Crashlytics with enhanced metadata (directly, not via TPPErrorLogger)
    Crashlytics.crashlytics().setCustomValue(true, forKey: "enhanced_logging_enabled")
    Crashlytics.crashlytics().setCustomValue(getDeviceID(), forKey: "device_id")
    
    // Log stack trace to Crashlytics
    let stackTrace = Thread.callStackSymbols.joined(separator: "\n")
    Crashlytics.crashlytics().log("Enhanced Error: \(context)")
    Crashlytics.crashlytics().log("Error: \(error.localizedDescription)")
    Crashlytics.crashlytics().log("Stack Trace:\n\(stackTrace)")
    
    // Log metadata
    for (key, value) in metadata {
      Crashlytics.crashlytics().log("\(key): \(value)")
    }
    
    Log.info(#file, "✅ Enhanced error data sent to Firebase Analytics & Crashlytics")
  }
  
  /// Log download failure with full context
  func logDownloadFailure(
    book: TPPBook,
    reason: String,
    error: Error?,
    metadata: [String: Any] = [:]
  ) {
    guard isEnhancedLoggingEnabled() else {
      // Normal logging
      if let error = error {
        TPPErrorLogger.logError(error, summary: "Download failure: \(reason)", metadata: metadata)
      }
      return
    }
    
    // Enhanced download failure logging
    var enhancedMetadata = metadata
    enhancedMetadata["device_id"] = getDeviceID()
    enhancedMetadata["book_id"] = book.identifier
    enhancedMetadata["book_title"] = book.title
    enhancedMetadata["distributor"] = book.distributor ?? "unknown"
    enhancedMetadata["content_type"] = TPPBookContentTypeConverter.stringValue(of: book.defaultBookContentType)
    enhancedMetadata["stack_trace"] = Thread.callStackSymbols
    enhancedMetadata["reason"] = reason
    
    if let error = error {
      enhancedMetadata["error_domain"] = (error as NSError).domain
      enhancedMetadata["error_code"] = (error as NSError).code
      enhancedMetadata["error_description"] = error.localizedDescription
    }
    
    // Log to Crashlytics
    TPPErrorLogger.logError(
      withCode: .downloadFail,
      summary: "[ENHANCED] Download failure: \(reason) - \(book.title)",
      metadata: enhancedMetadata
    )
    
    // Send to Firebase Analytics
    Analytics.logEvent("enhanced_download_failure", parameters: [
      "book_id": book.identifier,
      "reason": reason,
      "device_id": getDeviceID(),
      "distributor": book.distributor ?? "unknown"
    ])
    
    Log.info(#file, "📊 Enhanced error logging captured for download failure")
  }
  
  /// Log network failure with full context
  func logNetworkFailure(
    url: URL?,
    error: Error,
    context: String,
    metadata: [String: Any] = [:]
  ) {
    guard isEnhancedLoggingEnabled() else {
      TPPErrorLogger.logError(error, summary: context, metadata: metadata)
      return
    }
    
    var enhancedMetadata = metadata
    enhancedMetadata["device_id"] = getDeviceID()
    enhancedMetadata["url"] = url?.absoluteString ?? "unknown"
    enhancedMetadata["error_domain"] = (error as NSError).domain
    enhancedMetadata["error_code"] = (error as NSError).code
    enhancedMetadata["stack_trace"] = Thread.callStackSymbols
    
    TPPErrorLogger.logError(error, summary: "[ENHANCED] Network: \(context)", metadata: enhancedMetadata)
    
    Analytics.logEvent("enhanced_network_error", parameters: [
      "url": url?.host ?? "unknown",
      "error_code": (error as NSError).code,
      "device_id": getDeviceID()
    ])
  }
  
  // MARK: - Device Info for Support
  
  func getDeviceInfo() async -> [String: String] {
    var info: [String: String] = [:]
    
    info["device_id"] = getDeviceID()
    
    // Access UIDevice on MainActor
    await MainActor.run {
      info["device_model"] = UIDevice.current.model
      info["ios_version"] = UIDevice.current.systemVersion
    }
    
    info["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    info["build_number"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    
    #if DEBUG
    info["build_type"] = "debug"
    #else
    info["build_type"] = "release"
    #endif
    
    return info
  }
}

