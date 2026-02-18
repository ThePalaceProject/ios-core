//
//  DeviceSpecificErrorMonitor.swift
//  Palace
//
//  Created for Remote Device-Specific Error Logging
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseAnalytics
import FirebaseCrashlytics

/// Lightweight error monitor that can be remotely enabled for specific devices.
/// Zero overhead when disabled, comprehensive logging when enabled.
///
/// NOTE: This class delegates all Firebase RemoteConfig access to FirebaseManager
/// to prevent race conditions that cause the "recursive_mutex lock failed" crash.
final class DeviceSpecificErrorMonitor {
  static let shared = DeviceSpecificErrorMonitor()
  
  private var isInitialized = false
  private let lock = NSLock()
  
  private init() {}
  
  // MARK: - Initialization
  
  /// Initializes the error monitor by fetching remote config.
  /// This should only be called once during app startup.
  func initialize() async {
    lock.lock()
    let alreadyInitialized = isInitialized
    if !alreadyInitialized {
      isInitialized = true
    }
    lock.unlock()
    
    guard !alreadyInitialized else { return }
    
    // Delegate to FirebaseManager for thread-safe remote config access
    await FirebaseManager.shared.fetchAndActivateRemoteConfig()
    Log.info(#file, "✅ Device-specific error monitor initialized")
  }
  
  // MARK: - Device ID
  
  func getDeviceID() -> String {
    FirebaseManager.shared.deviceID
  }
  
  // MARK: - Check if Enabled
  
  func isEnhancedLoggingEnabled() -> Bool {
    FirebaseManager.shared.isEnhancedLoggingEnabled()
  }
  
  // MARK: - Enhanced Error Logging
  
  /// Log error with full stack trace and context when enabled.
  /// NOTE: This should NOT call TPPErrorLogger to avoid infinite recursion.
  func logError(
    _ error: Error,
    context: String,
    metadata: [String: Any] = [:]
  ) {
    let isEnabled = isEnhancedLoggingEnabled()
    Log.info(#file, "🔍 logError called - Enhanced: \(isEnabled), context: \(context)")
    
    guard isEnabled else { return }
    
    Log.info(#file, "📊 ENHANCED logging active - capturing full stack trace")
    
    // Delegate to FirebaseManager for thread-safe Firebase access
    FirebaseManager.shared.logEnhancedErrorEvent(
      error: error,
      context: context,
      metadata: metadata
    )
  }
  
  /// Log download failure with full context.
  func logDownloadFailure(
    book: TPPBook,
    reason: String,
    error: Error?,
    metadata: [String: Any] = [:]
  ) {
    guard isEnhancedLoggingEnabled() else {
      if let error = error {
        TPPErrorLogger.logError(error, summary: "Download failure: \(reason)", metadata: metadata)
      }
      return
    }
    
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
    
    TPPErrorLogger.logError(
      withCode: .downloadFail,
      summary: "[ENHANCED] Download failure: \(reason) - \(book.title)",
      metadata: enhancedMetadata
    )
    
    Analytics.logEvent("enhanced_download_failure", parameters: [
      "book_id": book.identifier,
      "reason": reason,
      "device_id": getDeviceID(),
      "distributor": book.distributor ?? "unknown"
    ])
    
    Log.info(#file, "📊 Enhanced error logging captured for download failure")
  }
  
  /// Log network failure with full context.
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
  
  func getDeviceInfo() -> [String: String] {
    FirebaseManager.shared.getDeviceInfo()
  }
}
