//
//  BookCellModelCacheCleanupTests.swift
//  PalaceTests
//
//  The cell cache's stale-entry cleanup runs on the policy's housekeeping
//  ticks while the app is visible, and once on return to visible (PP-5508).
//

import XCTest
@testable import Palace

@MainActor
final class BookCellModelCacheCleanupTests: XCTestCase {

    private var scheduler: FakeActivityTickScheduler!
    private var policy: ActivityPolicy!
    private var appContainer: AppContainer!
    private var sut: BookCellModelCache!

    override func setUp() async throws {
        try await super.setUp()
        scheduler = FakeActivityTickScheduler()
        policy = makeTestActivityPolicy(scheduler: scheduler)
        appContainer = makeTestAppContainer()
        sut = BookCellModelCache(
            // A negative TTL makes every entry stale at once, so a cleanup
            // that runs empties the cache and one that does not leaves it full.
            configuration: .init(maxEntries: 10, unusedTTL: -1, observeRegistryChanges: false),
            imageCache: MockImageCache(),
            bookRegistry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            activityPolicy: policy
        )
    }

    override func tearDown() async throws {
        sut = nil
        appContainer = nil
        policy = nil
        scheduler = nil
        try await super.tearDown()
    }

    func testHousekeepingTick_WhileVisible_EvictsStaleEntries() {
        policy.setScene(.active)
        cacheTwoBooks()

        scheduler.fireAll()

        XCTAssertEqual(sut.count, 0)
    }

    func testWhileNotVisible_NoCleanupTimerIsArmed() {
        cacheTwoBooks()

        scheduler.fireAll()

        XCTAssertEqual(scheduler.armedIntervals, [], "launch state is background")
        XCTAssertEqual(sut.count, 2)
    }

    func testGoingToBackground_StopsTheCleanupTimer() {
        policy.setScene(.active)
        policy.setScene(.background)
        cacheTwoBooks()

        scheduler.fireAll()

        XCTAssertEqual(scheduler.armedIntervals, [60], "armed once while visible, not re-armed")
        XCTAssertEqual(sut.count, 2, "a stopped timer evicts nothing")
    }

    func testReturnToVisible_RunsOneCleanupWithoutATick() {
        policy.setScene(.active)
        policy.setScene(.background)
        cacheTwoBooks()

        policy.setScene(.active)

        XCTAssertEqual(sut.count, 0)
    }

    func testStateChangeWhileVisible_DoesNotRunACleanup() {
        policy.setScene(.active)
        cacheTwoBooks()

        policy.setScene(.inactive)
        policy.setPlayer(.mini)

        XCTAssertEqual(sut.count, 2, "only a transition to visible runs a cleanup")
    }

    func testWithoutPolicy_NoCleanupRuns() {
        let unscheduled = BookCellModelCache(
            configuration: .init(maxEntries: 10, unusedTTL: -1, observeRegistryChanges: false),
            imageCache: MockImageCache(),
            bookRegistry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService
        )
        _ = unscheduled.model(for: TPPBookMocker.mockBook(identifier: "c", title: "C", authors: "A"))

        policy.setScene(.active)
        scheduler.fireAll()

        XCTAssertEqual(unscheduled.count, 1, "a cache with no policy runs no cleanup")
    }

    private func cacheTwoBooks() {
        _ = sut.model(for: TPPBookMocker.mockBook(identifier: "a", title: "A", authors: "A"))
        _ = sut.model(for: TPPBookMocker.mockBook(identifier: "b", title: "B", authors: "B"))
        XCTAssertEqual(sut.count, 2)
    }
}
