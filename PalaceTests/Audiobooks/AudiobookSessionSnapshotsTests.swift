//
//  AudiobookSessionSnapshotsTests.swift
//  PalaceTests
//
//  The off-main mirrors of the playback session's main-actor state.
//

import XCTest
@testable import Palace

/// These mirrors exist to be read from the background MediaRemote queue, where
/// touching a `@MainActor` property traps. Each is written on main and read
/// from anywhere, so both ends are asserted: a write that never lands and a
/// read that never sees it fail the same way from the caller's side.
final class AudiobookSessionSnapshotsTests: XCTestCase {

    override func tearDown() {
        // Process-global, like the manager surface they were extracted from,
        // so a test that sets one must put it back or it leaks to the next.
        AudiobookSessionSnapshots.setHasActiveManager(false)
        AudiobookSessionSnapshots.setCurrentBookIdentifier(nil)
        super.tearDown()
    }

    // MARK: - Which book is loaded

    /// The round trip the archive re-download queue depends on: it reads this
    /// to serve the book being listened to before the rest of the shelf.
    func testCurrentBookIdentifier_isReadBackAfterItIsSet() {
        AudiobookSessionSnapshots.setCurrentBookIdentifier("urn:isbn:9780000000001")

        XCTAssertEqual(
            AudiobookSessionSnapshots.currentBookIdentifier,
            "urn:isbn:9780000000001"
        )
    }

    /// Clearing it is the half that matters on teardown. Without it the drain
    /// keeps prioritising a book nobody is playing, which starves the one the
    /// patron is actually waiting on — the behaviour the ordering exists for.
    func testCurrentBookIdentifier_isClearedWhenPlaybackStops() {
        AudiobookSessionSnapshots.setCurrentBookIdentifier("urn:isbn:9780000000002")

        AudiobookSessionSnapshots.setCurrentBookIdentifier(nil)

        XCTAssertNil(
            AudiobookSessionSnapshots.currentBookIdentifier,
            "a stale identifier makes the queue favour a book that is not playing"
        )
    }

    /// Opening a second book replaces the first rather than accumulating.
    func testCurrentBookIdentifier_isReplacedByTheNextBook() {
        AudiobookSessionSnapshots.setCurrentBookIdentifier("urn:isbn:9780000000003")
        AudiobookSessionSnapshots.setCurrentBookIdentifier("urn:isbn:9780000000004")

        XCTAssertEqual(
            AudiobookSessionSnapshots.currentBookIdentifier,
            "urn:isbn:9780000000004"
        )
    }

    /// Readable off the main actor, which is the entire reason it is not just
    /// a property on the `@MainActor` manager.
    func testCurrentBookIdentifier_isReadableOffTheMainActor() async {
        AudiobookSessionSnapshots.setCurrentBookIdentifier("urn:isbn:9780000000005")

        let read = await Task.detached { AudiobookSessionSnapshots.currentBookIdentifier }.value

        XCTAssertEqual(read, "urn:isbn:9780000000005")
    }

    // MARK: - Is a manager bound

    func testHasActiveManager_isReadBackAfterItIsSet() {
        AudiobookSessionSnapshots.setHasActiveManager(true)

        XCTAssertTrue(AudiobookSessionSnapshots.hasActiveManager)
    }

    func testHasActiveManager_isClearedOnTeardown() {
        AudiobookSessionSnapshots.setHasActiveManager(true)

        AudiobookSessionSnapshots.setHasActiveManager(false)

        XCTAssertFalse(AudiobookSessionSnapshots.hasActiveManager)
    }

    func testHasActiveManager_isReadableOffTheMainActor() async {
        AudiobookSessionSnapshots.setHasActiveManager(true)

        let read = await Task.detached { AudiobookSessionSnapshots.hasActiveManager }.value

        XCTAssertTrue(read)
    }

    /// The two mirrors are independent: the extraction put them in one type,
    /// and a shared lock or a copy-paste slip would couple them.
    func testTheTwoMirrors_doNotShadowEachOther() {
        AudiobookSessionSnapshots.setHasActiveManager(true)
        AudiobookSessionSnapshots.setCurrentBookIdentifier(nil)

        XCTAssertTrue(AudiobookSessionSnapshots.hasActiveManager)
        XCTAssertNil(AudiobookSessionSnapshots.currentBookIdentifier)

        AudiobookSessionSnapshots.setHasActiveManager(false)
        AudiobookSessionSnapshots.setCurrentBookIdentifier("urn:isbn:9780000000006")

        XCTAssertFalse(AudiobookSessionSnapshots.hasActiveManager)
        XCTAssertEqual(AudiobookSessionSnapshots.currentBookIdentifier, "urn:isbn:9780000000006")
    }
}
