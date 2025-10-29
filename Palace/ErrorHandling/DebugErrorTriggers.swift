//
//  DebugErrorTriggers.swift
//  Palace
//
//  Created for Testing Enhanced Error Logging
//  Copyright © 2025 The Palace Project. All rights reserved.
//

#if DEBUG
import Foundation

/// Debug-only error triggers for testing enhanced error logging
enum DebugErrorTriggers {
  
  /// Trigger a simulated download error
  static func triggerDownloadError() {
    Task {
      let testBook = createTestBook()
      let error = NSError(
        domain: "TestErrorDomain",
        code: 9999,
        userInfo: [
          NSLocalizedDescriptionKey: "Test download failure for enhanced logging",
          "test_error": true
        ]
      )
      
      await DeviceSpecificErrorMonitor.shared.logDownloadFailure(
        book: testBook,
        reason: "DEBUG TEST: Simulated download failure",
        error: error,
        metadata: [
          "test_scenario": "download_failure",
          "trigger_source": "DebugErrorTriggers"
        ]
      )
      
      Log.info(#file, "🧪 Test download error triggered")
    }
  }
  
  /// Trigger a simulated network error
  static func triggerNetworkError() {
    Task {
      let testURL = URL(string: "https://test.palaceproject.io/test")!
      let error = NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorTimedOut,
        userInfo: [
          NSLocalizedDescriptionKey: "Test network timeout",
          "test_error": true
        ]
      )
      
      await DeviceSpecificErrorMonitor.shared.logNetworkFailure(
        url: testURL,
        error: error,
        context: "DEBUG TEST: Simulated network timeout",
        metadata: [
          "test_scenario": "network_timeout",
          "trigger_source": "DebugErrorTriggers"
        ]
      )
      
      Log.info(#file, "🧪 Test network error triggered")
    }
  }
  
  /// Trigger a generic error
  static func triggerGenericError() {
    Task {
      let error = NSError(
        domain: "TestGenericError",
        code: 12345,
        userInfo: [
          NSLocalizedDescriptionKey: "Test generic error for logging",
          "test_error": true,
          "error_category": "generic"
        ]
      )
      
      await DeviceSpecificErrorMonitor.shared.logError(
        error,
        context: "DEBUG TEST: Generic error test",
        metadata: [
          "test_scenario": "generic_error",
          "trigger_source": "DebugErrorTriggers",
          "additional_info": "This is a test error with extra metadata"
        ]
      )
      
      Log.info(#file, "🧪 Test generic error triggered")
    }
  }
  
  /// Trigger multiple errors in sequence
  static func triggerMultipleErrors() {
    Task {
      // Trigger 3 different errors with delay
      triggerDownloadError()
      
      try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
      triggerNetworkError()
      
      try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
      triggerGenericError()
      
      Log.info(#file, "🧪 Multiple test errors triggered")
    }
  }
  
  // MARK: - Helper
  
  private static func createTestBook() -> TPPBook {
    // Create a minimal test book for error logging
    let entry = TPPOPDSEntry()
    entry.identifier = "urn:test:debug-error-book"
    entry.title = "DEBUG Test Book"
    entry.distributor = "TestDistributor"
    
    return TPPBook(entry: entry) ?? TPPBook()
  }
}

// MARK: - UIViewController Extension for Easy Testing

extension UIViewController {
  /// Show debug error trigger menu (DEBUG builds only)
  @objc func showDebugErrorTriggers() {
    let alert = UIAlertController(
      title: "🧪 Debug Error Triggers",
      message: "Trigger test errors to verify enhanced logging is working.",
      preferredStyle: .actionSheet
    )
    
    alert.addAction(UIAlertAction(title: "Download Error", style: .default) { _ in
      DebugErrorTriggers.triggerDownloadError()
      self.showConfirmation("Download error triggered! Check console and Firebase.")
    })
    
    alert.addAction(UIAlertAction(title: "Network Error", style: .default) { _ in
      DebugErrorTriggers.triggerNetworkError()
      self.showConfirmation("Network error triggered! Check console and Firebase.")
    })
    
    alert.addAction(UIAlertAction(title: "Generic Error", style: .default) { _ in
      DebugErrorTriggers.triggerGenericError()
      self.showConfirmation("Generic error triggered! Check console and Firebase.")
    })
    
    alert.addAction(UIAlertAction(title: "Multiple Errors", style: .default) { _ in
      DebugErrorTriggers.triggerMultipleErrors()
      self.showConfirmation("Multiple errors triggered! Check console and Firebase.")
    })
    
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    
    present(alert, animated: true)
  }
  
  private func showConfirmation(_ message: String) {
    let alert = UIAlertController(
      title: "✅ Triggered",
      message: message,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
#endif

