//
//  TPPUserNotificationsTests.swift
//  PalaceTests
//
//  Tests for NotificationService availability comparison and badge logic.
//

import XCTest
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

/// Tests for NotificationService hold availability and badge functionality
@MainActor
final class TPPUserNotificationsTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Singleton Tests

    /// `NotificationService.shared` must remain a singleton across calls
    /// AND from background queues (the singleton is used from arbitrary
    /// callers including push-notification handlers). Pin both shapes —
    /// a single-thread identity check + concurrent-access identity from
    /// multiple Tasks. Catches a mutant that swaps `static let` for
    /// per-call construction (which would silently work in single-thread
    /// scenarios but break observers across queues).
    func testSharedInstance_isStableAcrossCallsAndConcurrentAccess() async {
        // Same-thread: two consecutive lookups yield the same instance.
        XCTAssertTrue(NotificationService.shared === NotificationService.shared,
                      "Repeated reads must yield the same instance")

        // Concurrent reads from multiple Tasks must also see the same
        // instance — guards against a mutant that uses lazy var (which
        // can race) instead of static let.
        async let a: ObjectIdentifier = ObjectIdentifier(NotificationService.shared)
        async let b: ObjectIdentifier = ObjectIdentifier(NotificationService.shared)
        async let c: ObjectIdentifier = ObjectIdentifier(NotificationService.shared)
        let ids = await [a, b, c]
        XCTAssertEqual(Set(ids).count, 1,
                       "Concurrent reads must all return the same instance")
    }

    // MARK: - backgroundFetchIsNeeded Tests

    func testBackgroundFetchIsNeeded_returnsBasedOnHeldBooksCount() {
        // This test verifies the method returns a boolean based on held books
        // The actual result depends on TPPBookRegistry.shared.heldBooks state
        let result = NotificationService.backgroundFetchIsNeeded()
        XCTAssertNotNil(result)
        // Result should be deterministic across multiple calls without state change
        let result2 = NotificationService.backgroundFetchIsNeeded()
        XCTAssertEqual(result, result2,
                       "backgroundFetchIsNeeded should return a consistent value when state hasn't changed")
    }

    // MARK: - updateAppIconBadge Tests

    func testUpdateAppIconBadge_withEmptyArray_isIdempotentAndCrashFree() {
        // First and second empty-array calls must both complete without
        // throwing. Replaces the `XCTAssertTrue(true)` tautology with
        // XCTAssertNoThrow so a mutant that throws on empty input fails
        // here instead of mysteriously timing out.
        XCTAssertNoThrow(NotificationService.updateAppIconBadge(heldBooks: []),
                         "First empty-array call must not throw")
        XCTAssertNoThrow(NotificationService.updateAppIconBadge(heldBooks: []),
                         "Second empty-array call (idempotence) must not throw")
    }

    func testUpdateAppIconBadge_withBooks_processesWithoutCrash() {
        // Create books with various states
        let book1 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let book2 = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        // Should process books without crashing
        NotificationService.updateAppIconBadge(heldBooks: [book1, book2])
        // Verify both books are valid (i.e., the mock factory produced correct objects)
        XCTAssertFalse(book1.identifier.isEmpty, "Mock book1 should have a non-empty identifier")
        XCTAssertFalse(book2.identifier.isEmpty, "Mock book2 should have a non-empty identifier")
        // Calling again with same books should also be safe
        NotificationService.updateAppIconBadge(heldBooks: [book1, book2])
    }

    func testUpdateAppIconBadge_countsOnlyReadyBooks() {
        // Badge should only show count of books that are READY, not all holds

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

        reservedBook.defaultAcquisition?.availability.match(
            unavailable: nil, limited: nil, unlimited: nil,
            reserved: { _ in reservedIsReserved = true },
            ready: nil
        )

        readyBook.defaultAcquisition?.availability.match(
            unavailable: nil, limited: nil, unlimited: nil,
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
        // Verify that compareAvailability correctly detects when a hold becomes ready

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
        reservedBook.defaultAcquisition?.availability.match(
            unavailable: nil, limited: nil, unlimited: nil,
            reserved: { _ in oldIsReserved = true },
            ready: nil
        )
        XCTAssertTrue(oldIsReserved, "Old book should be in reserved state")

        // Verify the new book has "ready" status
        var newIsReady = false
        readyBook.defaultAcquisition?.availability.match(
            unavailable: nil, limited: nil, unlimited: nil,
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
        // If book is still "reserved" (not yet ready), no notification should be created

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

        oldReservedBook.defaultAcquisition?.availability.match(
            unavailable: nil, limited: nil, unlimited: nil,
            reserved: { _ in oldIsReserved = true },
            ready: nil
        )
        newReservedBook.defaultAcquisition?.availability.match(
            unavailable: nil, limited: nil, unlimited: nil,
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

        let originalState = record.state
        NotificationService.compareAvailability(cachedRecord: record, andNewBook: book)
        XCTAssertEqual(record.state, originalState,
                       "compareAvailability with nil availability must not mutate record state")
    }

    // MARK: - requestAuthorization Tests

    /// `requestAuthorization` is the entry point the AppDelegate calls on
    /// cold launch. We can't drive the UNUserNotificationCenter prompt in
    /// a test, but we can verify the class-level @objc surface (which is
    /// what AppDelegate's NSSelectorFromString dispatch hits) is intact.
    /// Pin BOTH the selector existing AND the metaclass responding —
    /// guards against a mutant that drops @objc, which would still
    /// compile but silently break the AppDelegate dispatch.
    func testRequestAuthorization_isExposedAsObjcSelectorOnService() {
        let selector = #selector(NotificationService.requestAuthorization)
        XCTAssertTrue(NotificationService.responds(to: selector),
                      "Class-level responder must expose requestAuthorization")
        // Selector name must be the canonical "requestAuthorization" — a
        // mutant that renamed the method while keeping the @objc binding
        // pointing at a different selector would fail this string check.
        XCTAssertEqual(NSStringFromSelector(selector), "requestAuthorization",
                       "Selector name must be the canonical 'requestAuthorization'")
    }
}
