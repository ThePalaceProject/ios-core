//
//  RegistryPositionOtherLibraryTests.swift
//  PalaceTests
//
//  PP-5578: an audiobook keeps playing after the patron selects another library.
//  A position saved for a book of a library whose shelf is no longer in memory
//  is written to that library's registry file and read back when it loads again.
//

import XCTest
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class RegistryPositionOtherLibraryTests: XCTestCase {

    private let accountA = "acct-A-\(UUID().uuidString)"
    private let accountB = "acct-B-\(UUID().uuidString)"
    private var fixture: PositionRegistryFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = PositionRegistryFixture(account: accountA)
        await fixture.load(accountA)
        XCTAssertEqual(fixture.registry.loadedAccountID, accountA, "premise: library A is loaded")
    }

    override func tearDown() async throws {
        fixture.recorder.release.signal()
        await fixture.registry._awaitPendingPersistenceForTesting()
        fixture.removeFiles()
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var registry: TPPBookRegistry { fixture.registry }

    private func location(_ value: String) -> TPPBookLocation? {
        PositionRegistryFixture.location(value)
    }

    private func waitUntilLoaded(_ account: String) async -> Bool {
        for _ in 0..<1000 {
            if registry.loadedAccountID == account { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// Selects `account` the way the app does and waits for its shelf.
    private func select(_ account: String) async {
        fixture.scope.switchTo(account)
        let loaded = await waitUntilLoaded(account)
        XCTAssertTrue(loaded, "premise: \(account) loaded")
        await registry._awaitPendingPersistenceForTesting()
    }

    private func recordOnDisk(_ id: String, account: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixture.primaryURL(account))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        return try XCTUnwrap(records.first { ($0["metadata"] as? [String: Any])?["id"] as? String == id })
    }

    // MARK: - After a library switch

    /// A returning patron: library A already holds two books with positions.
    func testSetLocation_AfterSwitchingToAnotherLibrary_IsStoredInTheBooksLibraryAndReadBackThere() async {
        await fixture.addBooks(["a1", "a2"])
        registry.setLocation(location("a1-p0"), forIdentifier: "a1", account: accountA)
        registry.setLocation(location("a2-p0"), forIdentifier: "a2", account: accountA)
        await registry._awaitPendingPersistenceForTesting()
        await select(accountB)

        registry.setLocation(location("a1-p1"), forIdentifier: "a1", account: accountA)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "a1-p1", "a2": "a2-p0"],
                       "the position goes to library A's file and leaves its other book alone")
        XCTAssertNil(fixture.persistedLocations(accountB)?["a1"], "library B's file gets no book of A")
        XCTAssertNil(registry.location(forIdentifier: "a1"), "library B's shelf in memory gets no book of A")

        await select(accountA)

        XCTAssertEqual(registry.location(forIdentifier: "a1")?.locationString, "a1-p1",
                       "reopening the book in library A reads the position saved after the switch")
    }

    /// A patron who has just signed in to library A for the first time: no
    /// registry file existed before the first borrow.
    func testSetLocation_NewPatronFirstBorrowThenSwitch_IsStoredInTheBooksLibrary() async {
        XCTAssertNil(fixture.persistedLocations(accountA), "premise: a new patron has no registry file")
        await fixture.addBooks(["a1"])
        registry.setLocation(location("p0"), forIdentifier: "a1", account: accountA)
        await registry._awaitPendingPersistenceForTesting()
        await select(accountB)

        registry.setLocation(location("p1"), forIdentifier: "a1", account: accountA)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "p1"])
        await select(accountA)
        XCTAssertEqual(registry.location(forIdentifier: "a1")?.locationString, "p1")
    }

    func testSetLocationSync_AfterSwitchingToAnotherLibrary_IsOnDiskInTheBooksLibraryWhenItReturns() async {
        await fixture.addBooks(["a1"])
        await select(accountB)

        registry.setLocationSync(location("p-sync"), forIdentifier: "a1", account: accountA)

        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "p-sync"],
                       "the termination save must be on disk before it returns")
        XCTAssertNil(fixture.persistedLocations(accountB)?["a1"])
    }

    func testSetLocation_BookNotOnItsLibrarysShelf_WritesNothing() async {
        await fixture.addBooks(["a1"])
        await select(accountB)
        let writesBefore = fixture.primaryWrites(accountA)

        registry.setLocation(location("p1"), forIdentifier: "returned", account: accountA)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.primaryWrites(accountA), writesBefore, "a book library A no longer holds rewrites nothing")
        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": ""])
    }

    /// The refinement only adds the server annotation id, and the next position
    /// save replaces the location, so another library's file is not rewritten for it.
    func testSetLocationDeferringSave_AfterSwitchingToAnotherLibrary_WritesNoFile() async {
        await fixture.addBooks(["a1"])
        await select(accountB)
        let writesA = fixture.primaryWrites(accountA)
        let writesB = fixture.primaryWrites(accountB)

        registry.setLocationDeferringSave(location("p-id"), forIdentifier: "a1", account: accountA)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.primaryWrites(accountA), writesA)
        XCTAssertEqual(fixture.primaryWrites(accountB), writesB)
        XCTAssertNil(registry.location(forIdentifier: "a1"))
    }

    /// A session with no library writes through the selected library's shelf,
    /// which after the switch does not hold library A's book.
    func testSetLocation_NilLibrary_AfterSwitch_WritesThroughTheSelectedLibrary() async {
        await fixture.addBooks(["a1"])
        await select(accountB)
        await fixture.addBooks(["b1"])
        let writesA = fixture.primaryWrites(accountA)

        registry.setLocation(location("p1"), forIdentifier: "a1", account: nil)
        registry.setLocation(location("b-p1"), forIdentifier: "b1", account: nil)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.primaryWrites(accountA), writesA)
        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": ""])
        XCTAssertEqual(fixture.persistedLocations(accountB), ["b1": "b-p1"])
    }

    /// The write after the switch changes only the position: states and other
    /// fields stay as they are on disk until library A loads again.
    func testSetLocation_AfterSwitch_LeavesTheBooksStateOnDisk() async throws {
        registry.addBook(TPPBookMocker.mockBook(identifier: "a1", title: "Book a1", distributorType: .OpenAccessAudiobook),
                         location: nil, state: .downloadSuccessful, fulfillmentId: "f-1", readiumBookmarks: nil, genericBookmarks: nil)
        await registry._awaitPendingPersistenceForTesting()
        await select(accountB)
        let before = try recordOnDisk("a1", account: accountA)

        registry.setLocation(location("p1"), forIdentifier: "a1", account: accountA)

        var after = try recordOnDisk("a1", account: accountA)
        XCTAssertEqual((after["location"] as? [String: Any])?["locationString"] as? String, "p1")
        after["location"] = before["location"]
        XCTAssertEqual(after as NSDictionary, before as NSDictionary,
                       "a position write to another library must not rewrite its book state")
    }

    /// The selection has moved back to A but the switch has not been handled
    /// yet, so the store still holds B's shelf: the position goes to A's file
    /// and B's books stay out of it.
    func testSetLocation_SelectionMovedBackButOtherShelfStillLoaded_WritesOnlyTheBooksLibraryFile() async {
        await fixture.addBooks(["a1"])
        await select(accountB)
        await fixture.addBooks(["b1"])
        fixture.scope.switchToWithoutNotifying(accountA)

        registry.setLocation(location("p1"), forIdentifier: "a1", account: accountA)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "p1"])
        XCTAssertEqual(fixture.persistedLocations(accountB), ["b1": ""])
    }

    // MARK: - Same library

    /// A relaunch: the book's library is selected and its load has read the
    /// file but not finished. The change is queued behind the load, so the
    /// loaded shelf keeps it and the file is not written around the load.
    func testSetLocation_BooksLibraryLoadInFlight_IsKeptByTheLoadedShelf() async {
        await fixture.addBooks(["a1"])
        let holding = LoadHoldingDownloadService()
        let relaunch = PositionRegistryFixture(account: accountA, root: fixture.root, downloadService: holding)
        let loaded = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                relaunch.registry.load(account: accountA) { continuation.resume() }
            }
        }
        let reached = await waitOffMain(holding.reached, timeout: 10)
        XCTAssertTrue(reached, "premise: the load is reading its records")
        XCTAssertNil(relaunch.registry.loadedAccountID, "premise: the load has not finished")

        relaunch.registry.setLocation(location("p1"), forIdentifier: "a1", account: accountA)
        let writesWhileLoading = relaunch.primaryWrites(accountA)
        holding.release.signal()
        await loaded.value
        await relaunch.registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(writesWhileLoading, 0, "nothing writes the file while its load is in flight")
        XCTAssertEqual(relaunch.registry.location(forIdentifier: "a1")?.locationString, "p1")
        XCTAssertEqual(relaunch.persistedLocations(accountA), ["a1": "p1"])
    }

    func testSetLocationDeferringSave_BooksLibraryIsLoaded_UpdatesMemoryOnly() async {
        await fixture.addBooks(["a1"])
        let writesBefore = fixture.primaryWrites(accountA)

        registry.setLocationDeferringSave(location("p-id"), forIdentifier: "a1", account: accountA)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(registry.location(forIdentifier: "a1")?.locationString, "p-id")
        XCTAssertEqual(fixture.primaryWrites(accountA), writesBefore)
    }

    func testSetLocationSync_BooksLibraryIsLoaded_IsOnDiskWhenItReturns() async {
        await fixture.addBooks(["a1"])

        registry.setLocationSync(location("p-sync"), forIdentifier: "a1", account: accountA)

        XCTAssertEqual(registry.location(forIdentifier: "a1")?.locationString, "p-sync")
        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "p-sync"])
    }

    /// The selection has moved to B but the switch has not been handled yet, so
    /// the store still holds A's shelf: the position goes through it to A's file.
    func testSetLocation_SelectionMovedButShelfStillLoaded_WritesThroughTheLoadedShelf() async {
        await fixture.addBooks(["a1"])
        fixture.scope.switchToWithoutNotifying(accountB)

        registry.setLocation(location("p1"), forIdentifier: "a1", account: accountA)
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(registry.location(forIdentifier: "a1")?.locationString, "p1")
        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "p1"])
        XCTAssertNil(fixture.persistedLocations(accountB), "nothing is written under the selected library")
    }
}
