//
//  DebugSettings.swift
//  Palace
//
//  Debug settings for testing error scenarios and edge cases.
//  Only accessible via Developer Settings (hidden from production users).
//

import Foundation

#if DEBUG

/// Manages debug settings for testing error scenarios
/// All settings are stored in UserDefaults and only available in DEBUG builds
final class DebugSettings {
  
  static let shared = DebugSettings()
  
  private let defaults = UserDefaults.standard
  
  // MARK: - Keys
  
  private enum Keys {
    static let simulateBorrowError = "debug.simulateBorrowError"
    static let borrowErrorType = "debug.borrowErrorType"
    static let badgeLoggingEnabled = "debug.badgeLoggingEnabled"
    static let testHoldsConfiguration = "debug.testHoldsConfiguration"
  }
  
  // MARK: - Simulated Error Types
  
  enum SimulatedBorrowError: Int, CaseIterable {
    case none = 0
    case loanLimitReached
    case holdLimitReached
    case credentialsSuspended
    case genericServerError
    
    var displayName: String {
      switch self {
      case .none: return "None (Disabled)"
      case .loanLimitReached: return "Loan Limit Reached"
      case .holdLimitReached: return "Hold Limit Reached"
      case .credentialsSuspended: return "Credentials Suspended"
      case .genericServerError: return "Generic Server Error"
      }
    }
    
    var problemDocument: TPPProblemDocument? {
      switch self {
      case .none:
        return nil
      case .loanLimitReached:
        return TPPProblemDocument.fromDictionary([
          "type": TPPProblemDocument.TypePatronLoanLimit,
          "title": "Loan limit reached",
          "status": 403,
          "detail": "You have reached your checkout limit of 10 items. Please return a title to borrow more."
        ])
      case .holdLimitReached:
        return TPPProblemDocument.fromDictionary([
          "type": TPPProblemDocument.TypePatronHoldLimit,
          "title": "Hold limit reached",
          "status": 403,
          "detail": "You have reached your hold limit of 5 items. Please cancel a hold to place more."
        ])
      case .credentialsSuspended:
        return TPPProblemDocument.fromDictionary([
          "type": TPPProblemDocument.TypeCredentialsSuspended,
          "title": "Suspended credentials.",
          "status": 403,
          "detail": "Your library card has been suspended. Contact your branch library."
        ])
      case .genericServerError:
        return TPPProblemDocument.fromDictionary([
          "type": "http://librarysimplified.org/terms/problem/unknown",
          "title": "Server Error",
          "status": 500,
          "detail": "An unexpected error occurred on the server. Please try again later."
        ])
      }
    }
  }
  
  // MARK: - Properties
  
  /// The type of borrow error to simulate (or .none to disable)
  var simulatedBorrowError: SimulatedBorrowError {
    get {
      let rawValue = defaults.integer(forKey: Keys.borrowErrorType)
      return SimulatedBorrowError(rawValue: rawValue) ?? .none
    }
    set {
      defaults.set(newValue.rawValue, forKey: Keys.borrowErrorType)
    }
  }
  
  /// Whether borrow error simulation is enabled
  var isBorrowErrorSimulationEnabled: Bool {
    return simulatedBorrowError != .none
  }
  
  // MARK: - Error Generation
  
  /// Creates a simulated NSError with problem document for testing
  /// Returns nil if simulation is disabled
  func createSimulatedBorrowError() -> (error: NSError, problemDocument: TPPProblemDocument)? {
    guard let problemDoc = simulatedBorrowError.problemDocument else {
      return nil
    }
    
    Log.warn(#file, "⚠️ DEBUG: Simulating borrow error: \(simulatedBorrowError.displayName)")
    
    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "DebugSimulatedBorrowError",
      code: problemDoc.status ?? 403,
      userInfo: nil
    )
    
    return (error, problemDoc)
  }
  
  // MARK: - Badge Logging
  
  /// Whether badge update logging is enabled
  var isBadgeLoggingEnabled: Bool {
    get { defaults.bool(forKey: Keys.badgeLoggingEnabled) }
    set { defaults.set(newValue, forKey: Keys.badgeLoggingEnabled) }
  }
  
  // MARK: - Test Holds Configuration
  
  enum TestHoldsConfiguration: Int, CaseIterable {
    case none = 0
    case oneReserved           // 1 hold waiting in queue
    case oneReady              // 1 hold ready to borrow
    case mixedHolds            // 3 reserved + 1 ready
    case allReady              // 3 ready to borrow
    
    var displayName: String {
      switch self {
      case .none: return "None (Use Real Data)"
      case .oneReserved: return "1 Reserved (badge=0)"
      case .oneReady: return "1 Ready (badge=1)"
      case .mixedHolds: return "3 Reserved + 1 Ready (badge=1)"
      case .allReady: return "3 Ready (badge=3)"
      }
    }
    
    var expectedBadgeCount: Int {
      switch self {
      case .none: return -1 // Use real data
      case .oneReserved: return 0
      case .oneReady: return 1
      case .mixedHolds: return 1
      case .allReady: return 3
      }
    }
  }
  
  /// The test holds configuration to use
  var testHoldsConfiguration: TestHoldsConfiguration {
    get {
      let rawValue = defaults.integer(forKey: Keys.testHoldsConfiguration)
      return TestHoldsConfiguration(rawValue: rawValue) ?? .none
    }
    set {
      defaults.set(newValue.rawValue, forKey: Keys.testHoldsConfiguration)
    }
  }
  
  /// Whether test holds are enabled
  var isTestHoldsEnabled: Bool {
    return testHoldsConfiguration != .none
  }
  
  /// Creates test books based on the current configuration
  /// Returns nil if test holds are disabled
  func createTestHoldBooks() -> [TPPBook]? {
    guard isTestHoldsEnabled else { return nil }
    
    switch testHoldsConfiguration {
    case .none:
      return nil
      
    case .oneReserved:
      return [createReservedBook(index: 1)]
      
    case .oneReady:
      return [createReadyBook(index: 1)]
      
    case .mixedHolds:
      return [
        createReservedBook(index: 1),
        createReservedBook(index: 2),
        createReservedBook(index: 3),
        createReadyBook(index: 4)
      ]
      
    case .allReady:
      return [
        createReadyBook(index: 1),
        createReadyBook(index: 2),
        createReadyBook(index: 3)
      ]
    }
  }
  
  private func createReservedBook(index: Int) -> TPPBook {
    let titles = ["To Kill a Mockingbird", "1984", "The Great Gatsby", "Pride and Prejudice"]
    let authors = ["Harper Lee", "George Orwell", "F. Scott Fitzgerald", "Jane Austen"]
    let title = titles[(index - 1) % titles.count]
    let author = authors[(index - 1) % authors.count]
    
    let url = URL(string: "https://example.com/test-reserved-\(index)")!
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: url,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityReserved(
        holdPosition: UInt(index),
        copiesTotal: 5,
        since: Date(),
        until: Date().addingTimeInterval(86400 * 14)
      )
    )
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: author, relatedBooksURL: nil)],
      categoryStrings: ["Fiction"],
      distributor: "Test Library",
      identifier: "test-reserved-\(index)",
      imageURL: url,
      imageThumbnailURL: url,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: nil,
      summary: "Test book \(index) - reserved (waiting in queue)",
      title: title,
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: url,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: nil,
      imageCache: ImageCache.shared
    )
  }
  
  private func createReadyBook(index: Int) -> TPPBook {
    let titles = ["The Catcher in the Rye", "Brave New World", "Animal Farm", "Lord of the Flies"]
    let authors = ["J.D. Salinger", "Aldous Huxley", "George Orwell", "William Golding"]
    let title = titles[(index - 1) % titles.count]
    let author = authors[(index - 1) % authors.count]
    
    let url = URL(string: "https://example.com/test-ready-\(index)")!
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: url,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityReady(
        since: Date(),
        until: Date().addingTimeInterval(86400 * 3)
      )
    )
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: author, relatedBooksURL: nil)],
      categoryStrings: ["Fiction"],
      distributor: "Test Library",
      identifier: "test-ready-\(index)",
      imageURL: url,
      imageThumbnailURL: url,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: nil,
      summary: "Test book \(index) - ready to borrow!",
      title: title,
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: url,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: nil,
      imageCache: ImageCache.shared
    )
  }
  
  // MARK: - Reset
  
  /// Resets all debug settings to defaults
  func resetAll() {
    simulatedBorrowError = .none
    isBadgeLoggingEnabled = false
    testHoldsConfiguration = .none
  }
  
  private init() {}
}

#endif

