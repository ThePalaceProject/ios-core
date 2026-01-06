//
//  TPPSessionTests.swift
//  PalaceTests
//
//  Tests for TPPSession singleton pattern.
//

import XCTest
@testable import Palace

final class TPPSessionTests: XCTestCase {
  
  // MARK: - Singleton Tests
  
  func testSharedSession_returnsSameInstance() {
    let session1 = TPPSession.shared()
    let session2 = TPPSession.shared()
    
    XCTAssertTrue(session1 === session2, "sharedSession should always return the same instance")
  }
  
  func testSharedSession_isNotNil() {
    let session = TPPSession.shared()
    
    XCTAssertNotNil(session)
  }
  
  func testSharedSession_multipleCallsReturnSameObject() {
    // Call sharedSession multiple times and verify identity
    var sessions: [TPPSession] = []
    for _ in 0..<10 {
      sessions.append(TPPSession.shared())
    }
    
    let firstSession = sessions.first!
    for session in sessions {
      XCTAssertTrue(session === firstSession)
    }
  }
  
  // MARK: - Interface Tests
  
  func testTPPSession_hasUploadMethod() {
    let session = TPPSession.shared()
    
    // Verify the upload method exists by checking selector response
    XCTAssertTrue(session.responds(to: #selector(TPPSession.upload(with:completionHandler:))))
  }
  
  func testTPPSession_hasWithURLMethod() {
    let session = TPPSession.shared()
    
    // Verify the withURL method exists
    XCTAssertTrue(session.responds(to: #selector(TPPSession.withURL(_:shouldResetCache:completionHandler:))))
  }
}

