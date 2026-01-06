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
  
  // MARK: - Reset
  
  /// Resets all debug settings to defaults
  func resetAll() {
    simulatedBorrowError = .none
  }
  
  private init() {}
}

#endif

