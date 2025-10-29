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
    let key = "PalaceDeviceMonitoringID"
    if let existingID = UserDefaults.standard.string(forKey: key) {
      return existingID
    }
    
    let newID = UUID().uuidString
    UserDefaults.standard.set(newID, forKey: key)
    return newID
  }
  
  // MARK: - Check if Enabled
  
  func isEnhancedLoggingEnabled() -> Bool {
    // Check device-specific flag first (highest priority)
    let deviceID = getDeviceID()
    let deviceKey = "enhanced_error_logging_device_\(deviceID)"
    
    let deviceConfigValue = remoteConfig.configValue(forKey: deviceKey)
    if deviceConfigValue.source == .remote {
      return deviceConfigValue.boolValue
    }
    
    // Check global flag
    let globalValue = remoteConfig.configValue(forKey: "enhanced_error_logging_enabled")
    if globalValue.source == .remote {
      return globalValue.boolValue
    }
    
    // Default: disabled
    return false
  }
  
  // MARK: - Enhanced Error Logging
  
  /// Log error with full stack trace and context when enabled
  func logError(
    _ error: Error,
    context: String,
    metadata: [String: Any] = [:]
  ) {
    guard isEnhancedLoggingEnabled() else {
      // Normal logging only
      TPPErrorLogger.logError(error, summary: context, metadata: metadata)
      return
    }
    
    // Enhanced logging with stack trace
    var enhancedMetadata = metadata
    enhancedMetadata["device_id"] = getDeviceID()
    enhancedMetadata["stack_trace"] = Thread.callStackSymbols
    enhancedMetadata["enhanced_monitoring"] = true
    
    // Log to Crashlytics
    TPPErrorLogger.logError(error, summary: "[ENHANCED] \(context)", metadata: enhancedMetadata)
    
    // Also send to Firebase Analytics
    Analytics.logEvent("enhanced_error_logged", parameters: [
      "error_domain": (error as NSError).domain,
      "error_code": (error as NSError).code,
      "context": context,
      "device_id": getDeviceID()
    ])
    
    // Log to Crashlytics with custom key
    Crashlytics.crashlytics().setCustomValue(true, forKey: "enhanced_logging_enabled")
    Crashlytics.crashlytics().log("Enhanced Error: \(context) - \(error.localizedDescription)")
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
  
  nonisolated func getDeviceInfo() -> [String: String] {
    var info: [String: String] = [:]
    
    info["device_id"] = getDeviceID()
    info["device_model"] = UIDevice.current.model
    info["ios_version"] = UIDevice.current.systemVersion
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

