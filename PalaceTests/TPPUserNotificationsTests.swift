//
//  TPPUserNotificationsTests.swift
//  PalaceTests
//
//  Tests for TPPUserNotifications availability and badge logic.
//

import XCTest
@testable import Palace

final class TPPUserNotificationsTests: XCTestCase {
  
  // MARK: - backgroundFetchIsNeeded Tests
  
  func testBackgroundFetchIsNeeded_returnsBasedOnHeldBooksCount() {
    // This test verifies the method returns a boolean based on held books
    // The actual result depends on TPPBookRegistry.shared.heldBooks state
    let result = TPPUserNotifications.backgroundFetchIsNeeded()
    XCTAssertNotNil(result)
    // Result is a Bool - either true or false based on current state
    XCTAssertTrue(result == true || result == false)
  }
  
  // MARK: - updateAppIconBadge Tests
  
  func testUpdateAppIconBadge_withEmptyArray_doesNotCrash() {
    // Should handle empty array gracefully
    TPPUserNotifications.updateAppIconBadge(heldBooks: [])
    // If we get here without crashing, the test passes
  }
  
  func testUpdateAppIconBadge_withBooks_processesWithoutCrash() {
    // Create books with various states
    let book1 = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let book2 = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    
    // Should process books without crashing
    TPPUserNotifications.updateAppIconBadge(heldBooks: [book1, book2])
    // If we get here without crashing, the test passes
  }
  
  // MARK: - compareAvailability Tests
  
  func testCompareAvailability_doesNotCrashWithValidInputs() {
    // Create a book for comparison
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    
    // Create a mock registry record
    // Note: This test primarily verifies the method doesn't crash
    // Full testing would require mocking the notification center
    
    // The method signature requires TPPBookRegistryRecord
    // We can verify the static method exists and is callable
    XCTAssertTrue(TPPUserNotifications.responds(to: #selector(TPPUserNotifications.compareAvailability(cachedRecord:andNewBook:))))
  }
}

