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
      let testBook = await createTestBook()
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
  
  private static func createTestBook() async -> TPPBook {
    // Use any book from the registry as a test book
    let allBooks = TPPBookRegistry.shared.allBooks
    
    if let book = allBooks.first {
      return book
    }
    
    // If no books in registry, create a minimal mock
    let mockDict: [String: Any] = [
      "id": "urn:test:debug-book",
      "title": "Test Book for Error Logging",
      "updated": "2025-10-29T00:00:00Z",
      "@type": "http://schema.org/Book"
    ]
    
    return TPPBook(dictionary: mockDict) ?? {
      // Absolute fallback - shouldn't reach here in normal usage
      Log.warn(#file, "Using fallback test book - add some books to your library for better testing")
      return TPPBook(dictionary: [:])!
    }()
  }
}
#endif

