//
//  ChapterNavigationHoldTests.swift
//  PalaceTests
//
//  PP-5205 — the hold an explicit chapter selection keeps on the displayed chapter
//  until the seek it started produces a position for that chapter.
//
//  `ChapterNavigationPolicyTests` asserts the decision table; this asserts the
//  MECHANISM the hub actually calls — that the hold is armed by a selection, is not
//  released by traffic from the track being left, is released by the target's own
//  update, and is bounded so a seek that never lands cannot freeze the label.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class ChapterNavigationHoldTests: XCTestCase {

    private let leaving = "track-18"
    private let target = "track-42"

    // MARK: - beginSelection

    func testBeginSelection_aDifferentChapter_publishesImmediately() {
        let hold = ChapterNavigationHold()
        XCTAssertTrue(hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        ), "the tap must move the label without waiting for the seek")
    }

    func testBeginSelection_theChapterAlreadyPlaying_publishesNothing() {
        let hold = ChapterNavigationHold()
        XCTAssertFalse(hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: target, currentTitle: "Chapter 42"
        ), "re-tapping the playing chapter must not re-announce it")
    }

    func testBeginSelection_armsTheHoldEvenWhenItPublishesNothing() {
        // The publish decision and the hold are independent: re-tapping the playing
        // chapter still starts a seek, and the old playhead still ticks through it.
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: target, currentTitle: "Chapter 42"
        )
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "a hold armed by a no-publish selection must still hold")
    }

    // MARK: - the hold

    func testHold_ignoresTheTrackBeingLeft() {
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "the old playhead still ticking must not pull the label back")
    }

    func testHold_doesNotExpireOnRepeatedTrafficFromTheTrackBeingLeft() {
        // The hold is keyed on content, not counted down: a slow seek emits many of
        // these, and a hold that gave up after the first would show the same defect
        // a moment later.
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        for _ in 0..<5 {
            XCTAssertFalse(hold.shouldPublish(
                incomingKey: leaving, incomingTitle: "Chapter 18",
                currentKey: target, currentTitle: "Chapter 42"
            ))
        }
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: "track-7", incomingTitle: "Chapter 7",
            currentKey: target, currentTitle: "Chapter 42"
        ), "a third track is no more the target than the one being left")
    }

    func testHold_releasesWhenTheTargetsOwnUpdateArrives() {
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        // The seek lands. The label already names it, so nothing is published —
        // but the hold must end here, not merely stay satisfied.
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: target, incomingTitle: "Chapter 42",
            currentKey: target, currentTitle: "Chapter 42"
        ))
        XCTAssertTrue(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "once the seek has landed, an ordinary rollover must be honoured again")
    }

    func testRelease_endsTheHold() {
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        hold.release()
        XCTAssertTrue(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "a hold must not outlive the session that armed it")
    }

    func testSecondSelection_supersedesTheFirst() {
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        _ = hold.beginSelection(
            selectedKey: "track-7", selectedTitle: "Chapter 7",
            currentKey: target, currentTitle: "Chapter 42"
        )
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: target, incomingTitle: "Chapter 42",
            currentKey: "track-7", currentTitle: "Chapter 7"
        ), "the superseded target must no longer satisfy the hold")
        XCTAssertTrue(hold.shouldPublish(
            incomingKey: "track-7", incomingTitle: "Chapter 7",
            currentKey: target, currentTitle: "Chapter 42"
        ))
    }

    // MARK: - the bound

    func testHold_expiresAfterTheTimeout_soAFailedSeekCannotFreezeTheLabel() async throws {
        // A seek that never produces a position for its target would otherwise hold
        // the label forever — pinned to a chapter that is not playing, and deaf to
        // every real chapter change after it.
        //
        // The bound is INJECTED rather than slept through at its production 3s: a
        // multi-second sleep on a suite that runs three iterations measures the
        // machine as much as the code. The production default is asserted separately
        // below, so shortening the test cannot quietly shorten the product.
        let hold = ChapterNavigationHold(timeoutSeconds: 0.2)
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "premise: the hold is armed")

        try await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertTrue(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "the bound did not fire — a seek that never lands freezes the chapter label")
    }

    func testDefaultTimeout_matchesTheToolkitNavigationTimeout() {
        // The injected bound above proves the mechanism; this pins the SHIPPED value,
        // so the two layers cannot disagree about when a seek is abandoned.
        XCTAssertEqual(ChapterNavigationHold.defaultTimeoutSeconds, 3.0, accuracy: 0.001)
    }

    // MARK: - cells the first round left empty

    func testHold_ignoresAPositionForTheCHAPTERCURRENTLYSHOWN_whenHeldForAnother() {
        // The guard-ORDER cell. `ChapterChangeDetector` would say "no change" here, so
        // a hold checked AFTER the change test would fall through to `.releaseHold`
        // and quietly drop the hold on a tick from the track being left. Unreachable
        // through `skipToChapter` today — it always makes current == target — but
        // nothing pins that, and the order is the thing under test.
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: leaving, currentTitle: "Chapter 18"
        ), "a tick matching the DISPLAYED chapter is still not the target")

        // ...and the hold must survive it, which is what a wrongly-ordered guard breaks.
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "the hold was released by a tick that never named the target")
    }

    func testHold_satisfiedByTheTarget_whenNothingIsDisplayedYet() {
        // nil current makes ChapterChangeDetector fire unconditionally; pair it with a
        // SATISFIED hold so the release path is exercised on the first-emit row too.
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: nil, currentTitle: nil
        )
        XCTAssertTrue(hold.shouldPublish(
            incomingKey: target, incomingTitle: "Chapter 42",
            currentKey: nil, currentTitle: nil
        ))
    }

    func testChapterToPublish_withNoIncomingChapter_publishesNothingAndKeepsTheHold() {
        // `manager?.currentChapter` is optional at the call site
        // (`AudiobookSessionManager.handlePositionUpdate`), and a nil there must not
        // count as the seek landing.
        let hold = ChapterNavigationHold()
        _ = hold.beginSelection(
            selectedKey: target, selectedTitle: "Chapter 42",
            currentKey: leaving, currentTitle: "Chapter 18"
        )
        XCTAssertNil(hold.chapterToPublish(from: nil, replacing: nil))
        XCTAssertFalse(hold.shouldPublish(
            incomingKey: leaving, incomingTitle: "Chapter 18",
            currentKey: target, currentTitle: "Chapter 42"
        ), "a nil incoming chapter must not have released the hold")
    }
}
