//
//  RegistryPositionCoalescingTests.swift
//  PalaceTests
//
//  PP-5507: a `.coalesced` position change updates the in-memory record at once
//  and reaches the registry file at most once per 15 s per book, or at a flush
//  (reader close, background, terminate, account switch). A sign-out removes the
//  shelf files after every save already scheduled, and a save scheduled before
//  the sign-out does not write the old shelf back.
//

import XCTest
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class RegistryPositionCoalescingTests: XCTestCase {

    private let accountA = "acct-A-\(UUID().uuidString)"
    private let accountB = "acct-B-\(UUID().uuidString)"
    private var fixture: PositionRegistryFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = PositionRegistryFixture(account: accountA)
        await fixture.load(accountA)
        XCTAssertEqual(fixture.registry.loadedAccountID, accountA, "premise: account A is loaded")
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

    private func setPosition(_ value: String, for id: String, _ persistence: RegistryPositionPersistence) async {
        registry.setLocation(PositionRegistryFixture.location(value), forIdentifier: id, persistence: persistence)
        await registry._awaitPendingPersistenceForTesting()
    }

    private func memoryPosition(_ id: String) -> String? {
        registry.location(forIdentifier: id)?.locationString
    }

    private func waitUntilLoaded(_ account: String) async -> Bool {
        for _ in 0..<1000 {
            if registry.loadedAccountID == account { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: - Coalescing

    func testCoalesced_TenPositionsWithinFifteenSeconds_OneDiskWriteAndEveryPositionInMemory() async {
        await fixture.addBooks(["a1"])
        let writesBefore = fixture.primaryWrites(accountA)

        for turn in 0..<10 {
            await setPosition("p\(turn)", for: "a1", .coalesced)
            XCTAssertEqual(memoryPosition("a1"), "p\(turn)", "page turn \(turn) must be current in memory at once")
            fixture.clock.advance(1.4)
        }

        XCTAssertEqual(fixture.primaryWrites(accountA) - writesBefore, 1,
                       "ten page turns inside 15 s must write the registry file once")
        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p0", "the first turn is written at once")
    }

    func testCoalesced_ChangeFifteenSecondsAfterTheLastWrite_WritesTheNewestPosition() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(10)
        await setPosition("p1", for: "a1", .coalesced)
        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p0", "premise: p1 is pending")

        fixture.clock.advance(5)
        await setPosition("p2", for: "a1", .coalesced)

        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p2",
                       "the first change 15 s after the last write must reach disk")
    }

    func testCoalesced_ChangeJustUnderFifteenSeconds_StaysPending() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        let writesBefore = fixture.primaryWrites(accountA)

        fixture.clock.advance(14.9)
        await setPosition("p1", for: "a1", .coalesced)

        XCTAssertEqual(fixture.primaryWrites(accountA), writesBefore, "14.9 s after a write is inside the interval")
        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p0")
        XCTAssertEqual(memoryPosition("a1"), "p1")
    }

    func testCoalesced_IntervalIsPerBook() async {
        await fixture.addBooks(["a1", "a2"])
        await setPosition("x0", for: "a1", .coalesced)
        fixture.clock.advance(1)

        await setPosition("y0", for: "a2", .coalesced)

        XCTAssertEqual(fixture.persistedLocations(accountA)?["a2"], "y0",
                       "a book whose position was never written is written at once")
    }

    func testImmediate_DefaultSetLocation_WritesEveryPosition() async {
        await fixture.addBooks(["a1"])
        let writesBefore = fixture.primaryWrites(accountA)

        for turn in 0..<3 {
            registry.setLocation(PositionRegistryFixture.location("p\(turn)"), forIdentifier: "a1")
            await registry._awaitPendingPersistenceForTesting()
            fixture.clock.advance(1)
        }

        XCTAssertEqual(fixture.primaryWrites(accountA) - writesBefore, 3,
                       "callers that do not ask for coalescing (audiobooks, PDF) keep one write per change")
        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p2")
    }

    func testImmediate_AfterPendingCoalescedPosition_LeavesNothingForFlush() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(1)
        await setPosition("p1", for: "a1", .coalesced)
        await setPosition("p2", for: "a1", .immediate)
        let writesBefore = fixture.primaryWrites(accountA)

        registry.flushPendingPositions()

        XCTAssertEqual(fixture.primaryWrites(accountA), writesBefore,
                       "an immediate write already stored the pending position")
        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p2")
    }

    // MARK: - Flush

    /// The app is scene-based, so background entry reaches `SceneDelegate`, not
    /// `applicationDidEnterBackground`; a pending page turn must be on disk after it.
    func testSceneDidEnterBackground_PendingPosition_IsOnDisk() async throws {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(1)
        await setPosition("p1", for: "a1", .coalesced)
        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p0", "premise: p1 is pending")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first)
        let sceneDelegate = SceneDelegate()
        let registry = registry
        sceneDelegate.positionRegistry = { registry }
        sceneDelegate.activityPolicy = ActivityPolicy(
            notificationCenter: NotificationCenter(),
            thermalState: { .nominal },
            isLowPowerModeEnabled: { false },
            scheduler: TimerTickScheduler()
        )

        sceneDelegate.sceneDidEnterBackground(scene)

        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p1")
    }

    func testFlush_PendingPosition_IsOnDiskWhenFlushReturns() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(1)
        await setPosition("p1", for: "a1", .coalesced)
        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p0", "premise: p1 is pending")

        registry.flushPendingPositions()

        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p1",
                       "background and terminate rely on the flush finishing before it returns")
    }

    func testFlush_RightAfterACoalescedCall_WritesThatCall() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(1)

        // The reader's close stores its last locator and flushes in one turn of the
        // main thread, before the store has run the change.
        registry.setLocation(PositionRegistryFixture.location("p1"), forIdentifier: "a1", persistence: .coalesced)
        registry.flushPendingPositions()

        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p1")
    }

    func testFlush_NothingPending_WritesNothing() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        let writesBefore = fixture.primaryWrites(accountA)

        registry.flushPendingPositions()
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.primaryWrites(accountA), writesBefore)
    }

    func testFlush_RestartsTheIntervalForThatBook() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(10)
        await setPosition("p1", for: "a1", .coalesced)
        registry.flushPendingPositions()

        fixture.clock.advance(10)
        await setPosition("p2", for: "a1", .coalesced)

        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "p1",
                       "10 s after the flush wrote p1, p2 is still inside the interval")
    }

    // MARK: - Reset

    func testReset_DropsPendingPositions() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(1)
        await setPosition("p1", for: "a1", .coalesced)

        registry.reset(accountA)
        registry.flushPendingPositions()
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.primaryURL(accountA).path),
                       "a flush after sign-out must not write the signed-out shelf back")
    }

    func testReset_NextPatronsFirstPosition_IsWrittenAtOnce() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        registry.reset(accountA)
        await fixture.load(accountA)
        await fixture.addBooks(["a1"])
        fixture.clock.advance(1)

        await setPosition("n0", for: "a1", .coalesced)

        XCTAssertEqual(fixture.persistedLocations(accountA)?["a1"], "n0",
                       "the previous patron's write time must not delay the next patron's first position")
    }

    func testReset_WithASaveWaitingOnTheDiskQueue_LeavesNoFileOfTheOldShelf() async {
        await fixture.addBooks(["a1"])
        let primary = fixture.primaryURL(accountA)
        fixture.recorder.holdNextPrimaryWrite(underDirectory: fixture.accountDirectory(accountA))
        registry.addBook(TPPBookMocker.mockBook(identifier: "a2", title: "a2", distributorType: .EpubZip), state: .holding)
        let held = await waitOffMain(fixture.recorder.held, timeout: 10)
        XCTAssertTrue(held, "premise: the save is waiting at its primary write")

        let registry = self.registry
        let accountA = self.accountA
        let resetDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registry.reset(accountA)
            resetDone.signal()
        }
        // Either the reset finished, or it waits for the held save. Both orders must
        // end with no file.
        _ = await waitOffMain(resetDone, timeout: 0.5)
        fixture.recorder.release.signal()
        let finished = await waitOffMain(resetDone, timeout: 20)
        XCTAssertTrue(finished, "reset must finish once the held save completes")
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path),
                       "a save queued before sign-out must not leave the old shelf on disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RegistryFileRecovery.backupURL(for: primary).path))
    }

    func testReset_DuringASavesSnapshotWindow_SaveDoesNotWriteTheOldShelfBack() async {
        await fixture.addBooks(["a1"])
        let primary = fixture.primaryURL(accountA)
        fixture.recorder.holdNextSaveSnapshot(account: accountA)
        let registry = self.registry
        let saveDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registry.saveSync()
            saveDone.signal()
        }
        let held = await waitOffMain(fixture.recorder.held, timeout: 10)
        XCTAssertTrue(held, "premise: the save holds account A's shelf and has not queued its write")

        registry.reset(accountA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path), "premise: sign-out removed the file")
        fixture.recorder.release.signal()
        let finished = await waitOffMain(saveDone, timeout: 20)
        XCTAssertTrue(finished)

        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path),
                       "a save that captured the shelf before sign-out must not write it after sign-out")
    }

    // MARK: - Account switch

    func testAccountSwitch_FlushesTheOutgoingPosition_AndNothingOfALandsInB() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(1)
        await setPosition("p1", for: "a1", .coalesced)

        fixture.scope.switchTo(accountB)
        let switched = await waitUntilLoaded(accountB)
        XCTAssertTrue(switched, "premise: account B loaded")
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "p1"],
                       "the switch must write A's newest position to A's file")
        XCTAssertNil(fixture.persistedLocations(accountB)?["a1"], "A's book must not reach B's file")
        XCTAssertNil(registry.location(forIdentifier: "a1"), "B's shelf in memory has no A book")
    }

    func testFlush_PendingPositionOfAnAccountNoLongerLoaded_DoesNotOverwriteThatAccountsFile() async {
        await fixture.addBooks(["a1"])
        await setPosition("p0", for: "a1", .coalesced)
        fixture.clock.advance(1)
        await setPosition("p1", for: "a1", .coalesced)
        await fixture.load(accountB)
        XCTAssertEqual(registry.loadedAccountID, accountB, "premise")
        fixture.scope.switchToWithoutNotifying(accountB)
        await fixture.addBooks(["b1"])

        registry.flushPendingPositions()
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.persistedLocations(accountA), ["a1": "p0"],
                       "the store holds B's shelf now, so writing A's file would put B's books in it")
        XCTAssertNil(fixture.persistedLocations(accountB)?["a1"])
    }
}
