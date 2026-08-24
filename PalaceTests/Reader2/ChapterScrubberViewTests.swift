//
//  ChapterScrubberViewTests.swift
//  The Palace Project
//
//  PP-5006: behavior spec for the scrubber control — the geometry that turns a
//  touch into a book fraction, and the state machine that decides when (and
//  whether) a scrub navigates.
//

import XCTest
@testable import Palace

@MainActor
final class ChapterScrubberViewTests: XCTestCase {

    /// Chapter starts at 0, 25%, 75%; 5 pages.
    private func makeModel() -> ChapterScrubberModel {
        ChapterScrubberModel(
            chapters: [
                .init(title: "One", startProgression: 0.0),
                .init(title: "Two", startProgression: 0.25),
                .init(title: "Three", startProgression: 0.75)
            ],
            positionProgressions: [0.0, 0.2, 0.4, 0.6, 0.8]
        )
    }

    /// 320pt wide. The track is inset by half the scrubbing thumb (19/2 = 9.5)
    /// at each end, so the usable track runs x = 9.5 ... 310.5, width 301.
    private func makeView(model: ChapterScrubberModel? = nil) -> ChapterScrubberView {
        let view = ChapterScrubberView(frame: CGRect(x: 0, y: 0, width: 320, height: 34))
        view.model = model ?? makeModel()
        view.layoutIfNeeded()
        return view
    }

    private let trackOrigin: CGFloat = 9.5
    private let trackWidth: CGFloat = 301

    private func x(forFraction fraction: Double) -> CGFloat {
        trackOrigin + trackWidth * CGFloat(fraction)
    }

    // MARK: - Geometry

    func testFraction_MapsATouchAcrossTheTrackToZeroThroughOne() {
        XCTAssertEqual(
            ChapterScrubberView.fraction(forTouchX: 60, trackOrigin: 10, trackWidth: 100, isRightToLeft: false),
            0.5,
            accuracy: 0.0001
        )
    }

    func testFraction_ClampsATouchDraggedOffEitherEndOfTheTrack() {
        XCTAssertEqual(
            ChapterScrubberView.fraction(forTouchX: -500, trackOrigin: 10, trackWidth: 100, isRightToLeft: false),
            0.0
        )
        XCTAssertEqual(
            ChapterScrubberView.fraction(forTouchX: 5000, trackOrigin: 10, trackWidth: 100, isRightToLeft: false),
            1.0
        )
    }

    func testFraction_MirrorsForRightToLeftLayouts() {
        XCTAssertEqual(
            ChapterScrubberView.fraction(forTouchX: 35, trackOrigin: 10, trackWidth: 100, isRightToLeft: true),
            0.75,
            accuracy: 0.0001
        )
    }

    func testFraction_OnAZeroWidthTrack_IsTheStartOfTheBookNotNaN() {
        let fraction = ChapterScrubberView.fraction(
            forTouchX: 40, trackOrigin: 10, trackWidth: 0, isRightToLeft: false
        )
        XCTAssertFalse(fraction.isNaN)
        XCTAssertEqual(fraction, 0.0)
    }

    func testThumbOffset_IsTheInverseOfTheTouchMapping() {
        let offset = ChapterScrubberView.thumbOffset(
            forFraction: 0.25, trackWidth: 100, isRightToLeft: false
        )
        XCTAssertEqual(offset, 25, accuracy: 0.0001)
        XCTAssertEqual(
            ChapterScrubberView.fraction(forTouchX: offset, trackOrigin: 0, trackWidth: 100, isRightToLeft: false),
            0.25,
            accuracy: 0.0001
        )
    }

    func testThumbOffset_MirrorsForRightToLeftLayouts() {
        XCTAssertEqual(
            ChapterScrubberView.thumbOffset(forFraction: 0.25, trackWidth: 100, isRightToLeft: true),
            75,
            accuracy: 0.0001
        )
    }

    func testThumbOffset_OnAZeroWidthTrack_IsZeroNotNaN() {
        let offset = ChapterScrubberView.thumbOffset(
            forFraction: 0.5, trackWidth: 0, isRightToLeft: false
        )
        XCTAssertFalse(offset.isNaN)
        XCTAssertEqual(offset, 0)
    }

    // MARK: - Dragging does not navigate

    func testDragging_DoesNotCommitUntilTheFingerLifts() {
        let view = makeView()
        var commits: [ChapterScrubberModel.Target] = []
        view.onCommit = { commits.append($0) }

        view.beginScrub(atX: x(forFraction: 0.1))
        view.updateScrub(toX: x(forFraction: 0.5))
        view.updateScrub(toX: x(forFraction: 0.9))

        XCTAssertTrue(commits.isEmpty, "a drag in flight must not navigate")
    }

    func testDragging_MovesTheThumbToWhereTheFingerIs() {
        let view = makeView()
        view.beginScrub(atX: x(forFraction: 0.5))
        XCTAssertEqual(view.progression, 0.5, accuracy: 0.005)
    }

    // MARK: - Release commits exactly once, where the drag indicated

    func testRelease_CommitsOnceAtThePositionShownDuringTheDrag() {
        let view = makeView()
        var commits: [ChapterScrubberModel.Target] = []
        view.onCommit = { commits.append($0) }

        view.beginScrub(atX: x(forFraction: 0.1))
        view.updateScrub(toX: x(forFraction: 0.8))
        view.endScrub(atX: x(forFraction: 0.8))

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.progression ?? -1, 0.8, accuracy: 0.005)
        XCTAssertEqual(commits.first?.chapterTitle, "Three")
    }

    func testRelease_WithoutACoordinate_CommitsTheLastDraggedPosition() {
        // A touch that ends without a location (cancelled gesture recognizer,
        // touch delivered with no point) must still land where the readout said.
        let view = makeView()
        var commits: [ChapterScrubberModel.Target] = []
        view.onCommit = { commits.append($0) }

        view.beginScrub(atX: x(forFraction: 0.6))
        view.endScrub(atX: nil)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.progression ?? -1, 0.6, accuracy: 0.005)
    }

    func testRelease_WithoutABegunScrub_DoesNothing() {
        let view = makeView()
        var commits = 0
        view.onCommit = { _ in commits += 1 }

        view.endScrub(atX: 100)

        XCTAssertEqual(commits, 0)
    }

    // MARK: - Cancel restores the patron's position

    func testCancel_RestoresTheOriginalPositionAndNavigatesNowhere() {
        let view = makeView()
        view.setProgression(0.3, animated: false)
        var commits = 0
        view.onCommit = { _ in commits += 1 }

        view.beginScrub(atX: x(forFraction: 0.9))
        view.updateScrub(toX: x(forFraction: 0.95))
        view.cancelScrub()

        XCTAssertEqual(view.progression, 0.3, accuracy: 0.0001)
        XCTAssertEqual(commits, 0, "a cancelled drag must never navigate")
        XCTAssertFalse(view.isScrubbing)
    }

    // MARK: - The reader's own location updates

    func testSetProgression_IsIgnoredWhileADragIsInFlight() {
        // The reader posts location changes continuously; one arriving mid-drag
        // must not yank the thumb out from under the patron's finger.
        let view = makeView()
        view.beginScrub(atX: x(forFraction: 0.7))

        view.setProgression(0.1, animated: false)

        XCTAssertEqual(view.progression, 0.7, accuracy: 0.005)
    }

    func testSetProgression_MovesTheThumbWhenNoDragIsInFlight() {
        let view = makeView()
        view.setProgression(0.42, animated: false)
        XCTAssertEqual(view.progression, 0.42, accuracy: 0.0001)
    }

    func testSetProgression_ClampsOutOfRangeAndNonFiniteInput() {
        let view = makeView()
        view.setProgression(3.5, animated: false)
        XCTAssertEqual(view.progression, 1.0)
        view.setProgression(.nan, animated: false)
        XCTAssertEqual(view.progression, 0.0)
    }

    // MARK: - Books with nothing to scrub through

    func testBeginScrub_IsRefusedWhenTheBookHasNowhereToScrubTo() {
        let view = makeView(model: ChapterScrubberModel(chapters: [], positionProgressions: []))
        var commits = 0
        view.onCommit = { _ in commits += 1 }

        XCTAssertFalse(view.beginScrub(atX: 100))
        XCTAssertFalse(view.isScrubbing)

        view.endScrub(atX: 200)
        XCTAssertEqual(commits, 0)
    }

    // MARK: - VoiceOver

    func testAccessibility_IsASingleAdjustableElement() {
        let view = makeView()
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertTrue(view.accessibilityTraits.contains(.adjustable))
        XCTAssertFalse(view.accessibilityLabel?.isEmpty ?? true)
    }

    func testAccessibilityIncrement_MovesAChapterForwardAndNavigates() {
        // VoiceOver has no drag: an adjustment IS the whole scrub.
        let view = makeView()
        view.setProgression(0.1, animated: false)
        var commits: [ChapterScrubberModel.Target] = []
        view.onCommit = { commits.append($0) }

        view.accessibilityIncrement()

        XCTAssertEqual(view.progression, 0.25, accuracy: 0.0001)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.chapterTitle, "Two")
    }

    func testAccessibilityDecrement_FromMidChapter_GoesToThatChaptersStart() {
        // Previous-track semantics: the first decrement rewinds to the top of
        // the chapter you are in, not past it.
        let view = makeView()
        view.setProgression(0.8, animated: false)
        var commits: [ChapterScrubberModel.Target] = []
        view.onCommit = { commits.append($0) }

        view.accessibilityDecrement()

        XCTAssertEqual(view.progression, 0.75, accuracy: 0.0001)
        XCTAssertEqual(commits.first?.chapterTitle, "Three")
    }

    func testAccessibilityDecrement_Repeated_KeepsMovingBackwardThroughChapters() {
        // The second decrement must clear the boundary rather than wedging on it.
        let view = makeView()
        view.setProgression(0.8, animated: false)
        var commits: [ChapterScrubberModel.Target] = []
        view.onCommit = { commits.append($0) }

        view.accessibilityDecrement()
        view.accessibilityDecrement()

        XCTAssertEqual(view.progression, 0.25, accuracy: 0.0001)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.last?.chapterTitle, "Two")
    }

    func testAccessibilityValue_AnnouncesTheNewPositionAfterEveryAdjustment() {
        let view = makeView()
        view.setProgression(0.0, animated: false)

        view.accessibilityIncrement()
        let afterFirst = view.accessibilityValue
        view.accessibilityIncrement()
        let afterSecond = view.accessibilityValue

        XCTAssertNotEqual(afterFirst, afterSecond, "the spoken value must change as the position does")
        XCTAssertTrue(afterFirst?.contains("Two") ?? false, afterFirst ?? "nil")
        XCTAssertTrue(afterSecond?.contains("Three") ?? false, afterSecond ?? "nil")
    }

    func testAccessibilityAdjustment_IsRefusedWhenTheBookHasNowhereToScrubTo() {
        let view = makeView(model: ChapterScrubberModel(chapters: [], positionProgressions: []))
        var commits = 0
        view.onCommit = { _ in commits += 1 }

        view.accessibilityIncrement()
        view.accessibilityDecrement()

        XCTAssertEqual(commits, 0)
    }

    func testAccessibilityValue_TracksTheThumbWhenTheReaderMovesOnItsOwn() {
        let view = makeView()
        view.setProgression(0.8, animated: false)
        XCTAssertTrue(view.accessibilityValue?.contains("Three") ?? false, view.accessibilityValue ?? "nil")
    }

    // MARK: - Hit target

    func testHitArea_IsGrownToAComfortableTouchTarget() {
        // The control is 34pt tall; a touch 4pt above it must still land.
        let view = makeView()
        XCTAssertTrue(view.point(inside: CGPoint(x: 160, y: -4), with: nil))
        XCTAssertTrue(view.point(inside: CGPoint(x: 160, y: 38), with: nil))
        XCTAssertFalse(view.point(inside: CGPoint(x: 160, y: -40), with: nil))
    }
}

// MARK: - Reader chrome participation

@MainActor
final class ChapterScrubberChromeVisibilityTests: XCTestCase {

    func testScrubber_IsVisibleInImmersiveReadingAlongsideTheProgressLabels() {
        // Palace's progress chrome lives in immersive mode: the position label
        // is on screen precisely while the navigation bar is hidden. The
        // scrubber joins THAT chrome, not the navigation bar.
        XCTAssertFalse(
            TPPBaseReaderViewController.chapterScrubberHidden(
                navigationBarHidden: true, voiceOverRunning: false)
        )
    }

    func testScrubber_GetsOutOfTheWayWhenTheNavigationBarComesIn() {
        XCTAssertTrue(
            TPPBaseReaderViewController.chapterScrubberHidden(
                navigationBarHidden: false, voiceOverRunning: false)
        )
    }

    func testScrubber_TracksTheOverlayLabelsExceptUnderVoiceOver() {
        // Same chrome, same rule — the scrubber must not appear or vanish on a
        // different tap than the labels it sits above.
        for navigationBarHidden in [true, false] {
            XCTAssertEqual(
                TPPBaseReaderViewController.chapterScrubberHidden(
                    navigationBarHidden: navigationBarHidden, voiceOverRunning: false),
                TPPBaseReaderViewController.overlayLabelsHidden(
                    navigationBarHidden: navigationBarHidden, voiceOverRunning: false),
                "scrubber and overlay labels disagree at navigationBarHidden=\(navigationBarHidden)"
            )
        }
    }

    func testScrubber_StaysAvailableUnderVoiceOverUnlikeThePassiveOverlayLabels() {
        // The labels hide under VoiceOver because their content is surfaced
        // through the rotor. The scrubber is not content — it is the only
        // drag-free way to move through the book.
        for navigationBarHidden in [true, false] {
            XCTAssertTrue(
                TPPBaseReaderViewController.overlayLabelsHidden(
                    navigationBarHidden: navigationBarHidden, voiceOverRunning: true)
            )
            XCTAssertFalse(
                TPPBaseReaderViewController.chapterScrubberHidden(
                    navigationBarHidden: navigationBarHidden, voiceOverRunning: true)
            )
        }
    }
}
