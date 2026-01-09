//
//  ProblemDocumentTests.swift
//  PalaceTests
//
//  Tests for TPPProblemDocument parsing and error handling
//

import XCTest
@testable import Palace

final class ProblemDocumentTests: XCTestCase {
  
  // MARK: - Problem Document Creation Tests
  
  func testProblemDocument_fromData_parsesCorrectly() throws {
    let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-suspended",
      "title": "Suspended credentials.",
      "status": 403,
      "detail": "Your library card has been suspended. Contact your branch library."
    }
    """
    let data = json.data(using: .utf8)!
    
    let problemDoc = try TPPProblemDocument.fromData(data)
    
    XCTAssertEqual(problemDoc.type, TPPProblemDocument.TypeCredentialsSuspended)
    XCTAssertEqual(problemDoc.title, "Suspended credentials.")
    XCTAssertEqual(problemDoc.status, 403)
    XCTAssertEqual(problemDoc.detail, "Your library card has been suspended. Contact your branch library.")
  }
  
  func testProblemDocument_fromDictionary_parsesCorrectly() {
    let dict: [String: Any] = [
      "type": "http://librarysimplified.org/terms/problem/loan-limit-reached",
      "title": "Loan limit reached.",
      "status": 403,
      "detail": "You have reached your loan limit for this library."
    ]
    
    let problemDoc = TPPProblemDocument.fromDictionary(dict)
    
    XCTAssertEqual(problemDoc.type, TPPProblemDocument.TypePatronLoanLimit)
    XCTAssertEqual(problemDoc.title, "Loan limit reached.")
    XCTAssertEqual(problemDoc.status, 403)
    XCTAssertEqual(problemDoc.detail, "You have reached your loan limit for this library.")
  }
  
  func testProblemDocument_stringValue_combinesTitleAndDetail() throws {
    let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/hold-limit-reached",
      "title": "Hold limit reached",
      "detail": "You cannot place any more holds."
    }
    """
    let data = json.data(using: .utf8)!
    
    let problemDoc = try TPPProblemDocument.fromData(data)
    
    XCTAssertEqual(problemDoc.stringValue, "Hold limit reached: You cannot place any more holds.")
  }
  
  func testProblemDocument_stringValue_handlesMissingTitle() throws {
    let json = """
    {
      "detail": "Something went wrong."
    }
    """
    let data = json.data(using: .utf8)!
    
    let problemDoc = try TPPProblemDocument.fromData(data)
    
    XCTAssertEqual(problemDoc.stringValue, "Something went wrong.")
  }
  
  // MARK: - NSError Problem Document Extraction Tests
  
  func testNSError_problemDocument_extractsCorrectly() throws {
    let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-suspended",
      "title": "Account Suspended",
      "detail": "Please contact your library."
    }
    """
    let data = json.data(using: .utf8)!
    let problemDoc = try TPPProblemDocument.fromData(data)
    
    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "TestDomain",
      code: 403,
      userInfo: nil
    )
    
    XCTAssertNotNil(error.problemDocument)
    XCTAssertEqual(error.problemDocument?.title, "Account Suspended")
    XCTAssertEqual(error.problemDocument?.detail, "Please contact your library.")
    XCTAssertEqual(error.userFriendlyTitle, "Account Suspended")
    XCTAssertEqual(error.userFriendlyMessage, "Please contact your library.")
  }
  
  func testNSError_withoutProblemDocument_hasNilProperties() {
    let error = NSError(
      domain: "TestDomain",
      code: 500,
      userInfo: [NSLocalizedDescriptionKey: "Server error"]
    )
    
    XCTAssertNil(error.problemDocument)
    XCTAssertNil(error.userFriendlyTitle)
    // userFriendlyMessage falls back to localized description
    XCTAssertEqual(error.userFriendlyMessage, "Server error")
  }
  
  // MARK: - Problem Document Type Constants Tests
  
  func testProblemDocumentTypes_areCorrect() {
    XCTAssertEqual(
      TPPProblemDocument.TypeCredentialsSuspended,
      "http://librarysimplified.org/terms/problem/credentials-suspended"
    )
    XCTAssertEqual(
      TPPProblemDocument.TypePatronLoanLimit,
      "http://librarysimplified.org/terms/problem/loan-limit-reached"
    )
    XCTAssertEqual(
      TPPProblemDocument.TypePatronHoldLimit,
      "http://librarysimplified.org/terms/problem/hold-limit-reached"
    )
    XCTAssertEqual(
      TPPProblemDocument.TypeNoActiveLoan,
      "http://librarysimplified.org/terms/problem/no-active-loan"
    )
    XCTAssertEqual(
      TPPProblemDocument.TypeLoanAlreadyExists,
      "http://librarysimplified.org/terms/problem/loan-already-exists"
    )
    XCTAssertEqual(
      TPPProblemDocument.TypeInvalidCredentials,
      "http://librarysimplified.org/terms/problem/credentials-invalid"
    )
  }
  
  // MARK: - Problem Document Response Error Tests
  
  func testProblemDocument_fromResponseError_extractsFromNSError() throws {
    let json = """
    {
      "title": "Error from server",
      "detail": "Detailed message"
    }
    """
    let data = json.data(using: .utf8)!
    let problemDoc = try TPPProblemDocument.fromData(data)
    
    let nsError = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "Test",
      code: 400,
      userInfo: nil
    )
    
    let extracted = TPPProblemDocument.fromResponseError(nsError, responseData: nil)
    
    XCTAssertNotNil(extracted)
    XCTAssertEqual(extracted?.title, "Error from server")
    XCTAssertEqual(extracted?.detail, "Detailed message")
  }
  
  func testProblemDocument_fromResponseError_fallsBackToData() throws {
    let json = """
    {
      "title": "Data-based error",
      "detail": "From response data"
    }
    """
    let data = json.data(using: .utf8)!
    
    // Error without problem document
    let error = NSError(domain: "Test", code: 500, userInfo: nil)
    
    let extracted = TPPProblemDocument.fromResponseError(error, responseData: data)
    
    XCTAssertNotNil(extracted)
    XCTAssertEqual(extracted?.title, "Data-based error")
    XCTAssertEqual(extracted?.detail, "From response data")
  }
  
  func testProblemDocument_fromResponseError_returnsNilWhenNoDocument() {
    let error = NSError(domain: "Test", code: 500, userInfo: nil)
    let invalidData = "not json".data(using: .utf8)
    
    let extracted = TPPProblemDocument.fromResponseError(error, responseData: invalidData)
    
    XCTAssertNil(extracted)
  }
  
  // MARK: - Real-World Scenario Tests
  
  /// Tests the scenario from PP-3417: Sonoma County loan issue
  /// Server returns 403 with credentials-suspended problem document
  func testBorrowError_credentialsSuspended_extractsDetails() throws {
    // Simulates the actual server response from the ticket
    let serverResponse = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-suspended",
      "title": "Suspended credentials.",
      "status": 403,
      "detail": "Your library card has been suspended. Contact your branch library."
    }
    """
    let data = serverResponse.data(using: .utf8)!
    let problemDoc = try TPPProblemDocument.fromData(data)
    
    // Create an NSError like OPDSFeedService would
    let nsError = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "Api call failure: problem document available",
      code: TPPErrorCode.apiCall.rawValue,
      userInfo: nil
    )
    
    // Verify we can extract the user-friendly details
    XCTAssertEqual(nsError.userFriendlyTitle, "Suspended credentials.")
    XCTAssertEqual(
      nsError.userFriendlyMessage,
      "Your library card has been suspended. Contact your branch library."
    )
    
    // Verify the problem document is accessible
    XCTAssertNotNil(nsError.problemDocument)
    XCTAssertEqual(nsError.problemDocument?.type, TPPProblemDocument.TypeCredentialsSuspended)
  }
  
  /// Tests the scenario: patron reaches loan limit at Hinsdale Library
  func testBorrowError_loanLimitReached_extractsDetails() throws {
    let serverResponse = """
    {
      "type": "http://librarysimplified.org/terms/problem/loan-limit-reached",
      "title": "Loan limit reached",
      "status": 403,
      "detail": "You have reached your checkout limit. Please return a title to borrow more."
    }
    """
    let data = serverResponse.data(using: .utf8)!
    let problemDoc = try TPPProblemDocument.fromData(data)
    
    let nsError = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "Api call failure: problem document available",
      code: TPPErrorCode.apiCall.rawValue,
      userInfo: nil
    )
    
    XCTAssertEqual(nsError.userFriendlyTitle, "Loan limit reached")
    XCTAssertEqual(
      nsError.userFriendlyMessage,
      "You have reached your checkout limit. Please return a title to borrow more."
    )
  }
}

