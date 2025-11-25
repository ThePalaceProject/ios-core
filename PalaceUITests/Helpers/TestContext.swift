import Foundation
import XCTest

/// Context storage for sharing data between Cucumberish steps
///
/// **Purpose:**
/// - Store variables during test execution
/// - Retrieve values in later steps
/// - Enable complex scenarios with state
///
/// **Example:**
/// ```swift
/// // Save book info
/// TestContext.shared.save(bookInfo, forKey: "bookInfo")
///
/// // Retrieve later
/// if let bookInfo = TestContext.shared.get("bookInfo") as? BookInfo {
///   // Use bookInfo
/// }
/// ```
class TestContext {
  static let shared = TestContext()
  
  private var storage: [String: Any] = [:]
  
  private init() {}
  
  /// Save a value with a key
  func save(_ value: Any, forKey key: String) {
    storage[key] = value
  }
  
  /// Retrieve a value by key
  func get(_ key: String) -> Any? {
    storage[key]
  }
  
  /// Clear all stored values (call in tearDown)
  func clear() {
    storage.removeAll()
  }
  
  /// Check if key exists
  func contains(_ key: String) -> Bool {
    storage[key] != nil
  }
}

/// Book information model (matches your existing tests)
struct BookInfo {
  let title: String
  let author: String?
  let distributor: String?
  let bookType: String // EBOOK, AUDIOBOOK, PDF
  
  init(title: String, author: String? = nil, distributor: String? = nil, bookType: String = "EBOOK") {
    self.title = title
    self.author = author
    self.distributor = distributor
    self.bookType = bookType
  }
}

