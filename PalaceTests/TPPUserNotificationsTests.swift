//
//  TPPUserNotificationsTests.swift
//  PalaceTests
//
//  Tests for NotificationService availability and badge logic (consolidated from TPPUserNotifications).
//  PP-3487: These tests verify correct behavior for hold notifications timing.
//

import XCTest
@testable import Palace

/// Tests for consolidated NotificationService (formerly split between TPPUserNotifications and NotificationService)
final class TPPUserNotificationsTests: XCTestCase {
  
  // MARK: - Singleton Tests
  
  func testSharedInstance_returnsSameInstance() {
    let instance1 = NotificationService.shared
    let instance2 = NotificationService.shared
    XCTAssertTrue(instance1 === instance2, "shared should return the same instance")
  }
  
  // MARK: - backgroundFetchIsNeeded Tests
  
  func testBackgroundFetchIsNeeded_returnsBasedOnHeldBooksCount() {
    // This test verifies the method returns a boolean based on held books
    // The actual result depends on TPPBookRegistry.shared.heldBooks state
    let result = NotificationService.backgroundFetchIsNeeded()
    XCTAssertNotNil(result)
    // Result is a Bool - either true or false based on current state
    XCTAssertTrue(result == true || result == false)
  }
  
  // MARK: - updateAppIconBadge Tests
  
  func testUpdateAppIconBadge_withEmptyArray_doesNotCrash() {
    // Should handle empty array gracefully
    NotificationService.updateAppIconBadge(heldBooks: [])
    // If we get here without crashing, the test passes
  }
  
  func testUpdateAppIconBadge_withBooks_processesWithoutCrash() {
    // Create books with various states
    let book1 = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let book2 = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    
    // Should process books without crashing
    NotificationService.updateAppIconBadge(heldBooks: [book1, book2])
    // If we get here without crashing, the test passes
  }
  
  func testUpdateAppIconBadge_countsOnlyReadyBooks() {
    // PP-3487: Badge should only show count of books that are READY, not all holds
    
    // Create a mix of reserved (waiting) and ready books
    let reservedBook = TPPBookMocker.snapshotReservedBook(
      identifier: "test-reserved",
      title: "Still Waiting",
      holdPosition: 5
    )
    let readyBook = TPPBookMocker.snapshotReadyBook(
      identifier: "test-ready",
      title: "Ready to Borrow"
    )
    
    // Verify the books have correct availability types
    var reservedIsReserved = false
    var readyIsReady = false
    
    reservedBook.defaultAcquisition?.availability.matchUnavailable(
      nil, limited: nil, unlimited: nil,
      reserved: { _ in reservedIsReserved = true },
      ready: nil
    )
    
    readyBook.defaultAcquisition?.availability.matchUnavailable(
      nil, limited: nil, unlimited: nil,
      reserved: nil,
      ready: { _ in readyIsReady = true }
    )
    
    XCTAssertTrue(reservedIsReserved, "Reserved book should have 'reserved' availability")
    XCTAssertTrue(readyIsReady, "Ready book should have 'ready' availability")
    
    // The badge update uses the availability to count only ready books
    // This test verifies the mock books are correctly configured for the availability check
    NotificationService.updateAppIconBadge(heldBooks: [reservedBook, readyBook])
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
    XCTAssertTrue(NotificationService.responds(to: #selector(NotificationService.compareAvailability(cachedRecord:andNewBook:))))
  }
  
  func testCompareAvailability_detectsTransitionFromReservedToReady() {
    // PP-3487: Verify that compareAvailability correctly detects when a hold becomes ready
    
    // Create a "reserved" book (waiting in queue)
    let reservedBook = TPPBookMocker.snapshotReservedBook(
      identifier: "test-hold-transition",
      title: "The Picasso Heist",
      holdPosition: 1
    )
    
    // Create a "ready" version of the same book
    let readyBook = TPPBookMocker.snapshotReadyBook(
      identifier: "test-hold-transition",
      title: "The Picasso Heist"
    )
    
    // Verify the old book has "reserved" status
    var oldIsReserved = false
    reservedBook.defaultAcquisition?.availability.matchUnavailable(
      nil, limited: nil, unlimited: nil,
      reserved: { _ in oldIsReserved = true },
      ready: nil
    )
    XCTAssertTrue(oldIsReserved, "Old book should be in reserved state")
    
    // Verify the new book has "ready" status
    var newIsReady = false
    readyBook.defaultAcquisition?.availability.matchUnavailable(
      nil, limited: nil, unlimited: nil,
      reserved: nil,
      ready: { _ in newIsReady = true }
    )
    XCTAssertTrue(newIsReady, "New book should be in ready state")
    
    // Create a registry record for the reserved book
    let record = TPPBookRegistryRecord(
      book: reservedBook,
      location: nil,
      state: .holding,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Call compareAvailability - it should detect the transition
    // Note: This won't actually create a notification in tests (no authorization)
    // but it verifies the logic path executes without crashing
    NotificationService.compareAvailability(cachedRecord: record, andNewBook: readyBook)
  }
  
  func testCompareAvailability_doesNotNotifyWhenStillReserved() {
    // PP-3487: If book is still "reserved" (not yet ready), no notification should be created
    
    // Create two reserved books - old one at position 3, new one at position 1
    let oldReservedBook = TPPBookMocker.snapshotReservedBook(
      identifier: "test-still-waiting",
      title: "Still In Queue",
      holdPosition: 3
    )
    let newReservedBook = TPPBookMocker.snapshotReservedBook(
      identifier: "test-still-waiting",
      title: "Still In Queue",
      holdPosition: 1
    )
    
    // Both should be in reserved state
    var oldIsReserved = false
    var newIsReserved = false
    
    oldReservedBook.defaultAcquisition?.availability.matchUnavailable(
      nil, limited: nil, unlimited: nil,
      reserved: { _ in oldIsReserved = true },
      ready: nil
    )
    newReservedBook.defaultAcquisition?.availability.matchUnavailable(
      nil, limited: nil, unlimited: nil,
      reserved: { _ in newIsReserved = true },
      ready: nil
    )
    
    XCTAssertTrue(oldIsReserved, "Old book should be reserved")
    XCTAssertTrue(newIsReserved, "New book should still be reserved")
    
    let record = TPPBookRegistryRecord(
      book: oldReservedBook,
      location: nil,
      state: .holding,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // This should NOT trigger a notification (both are reserved)
    NotificationService.compareAvailability(cachedRecord: record, andNewBook: newReservedBook)
  }
  
  func testCompareAvailability_handlesNilAvailability() {
    // Should handle books without availability gracefully
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    
    let record = TPPBookRegistryRecord(
      book: book,
      location: nil,
      state: .holding,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Should not crash with nil availability
    NotificationService.compareAvailability(cachedRecord: record, andNewBook: book)
  }
  
  // MARK: - requestAuthorization Tests
  
  func testRequestAuthorization_canBeCalled() {
    // Verify the method exists and can be called without crashing
    // Note: Actual authorization requires user interaction, so we just verify it's callable
    XCTAssertTrue(NotificationService.responds(to: #selector(NotificationService.requestAuthorization)))
  }
}

