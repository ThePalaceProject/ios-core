//
//  PalaceSeekSliderAccessibilityTests.swift
//  PalaceTests
//
//  PP-5280: the audiobook seek bar must be adjustable with VoiceOver. A swipe
//  up or down moves the position by the patron's skip interval and seeks
//  through `onChange`, the same commit a finger drag ends with.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

@MainActor
final class PalaceSeekSliderAccessibilityTests: XCTestCase {

    private var host: AccessibilityAuditHost?
    private var seeks: [Double] = []

    override class func tearDown() {
        MainActor.assumeIsolated { AccessibilityRuntime.restore() }
        super.tearDown()
    }

    override func tearDown() {
        host?.tearDown()
        host = nil
        seeks = []
        super.tearDown()
    }

    // MARK: - VoiceOver adjustment

    func testSeekSlider_isExposedToVoiceOverAsAdjustable() throws {
        let slider = try mountSlider(at: 0.5)

        XCTAssertTrue(slider.traits.contains(.adjustable),
                      "traits were \(slider.traits.rawValue)")
    }

    /// 600 s chapter, 30 s forward step: one swipe up from the middle seeks
    /// to 0.55 through `onChange`, the commit a drag ends with.
    func testIncrement_seeksForwardByTheForwardStepThroughTheDragCommitPath() throws {
        let slider = try mountSlider(at: 0.5, chapterDuration: 600, forward: 30, back: 15)

        slider.object.accessibilityIncrement()
        host?.settle(0.1)

        XCTAssertEqual(seeks.count, 1)
        XCTAssertEqual(seeks.first ?? -1, 0.55, accuracy: 0.000_001)
    }

    /// The back step is its own setting: 15 s of a 600 s chapter is 0.025.
    func testDecrement_seeksBackByTheBackStepThroughTheDragCommitPath() throws {
        let slider = try mountSlider(at: 0.5, chapterDuration: 600, forward: 30, back: 15)

        slider.object.accessibilityDecrement()
        host?.settle(0.1)

        XCTAssertEqual(seeks.count, 1)
        XCTAssertEqual(seeks.first ?? -1, 0.475, accuracy: 0.000_001)
    }

    /// Two quick swipes step from the position the first one committed, not
    /// from the playback position, which has not caught up yet.
    func testRepeatedIncrements_accumulateFromTheCommittedPosition() throws {
        let slider = try mountSlider(at: 0.5, chapterDuration: 600, forward: 30, back: 15)

        slider.object.accessibilityIncrement()
        host?.settle(0.1)
        try liveSlider().object.accessibilityIncrement()
        host?.settle(0.1)

        XCTAssertEqual(seeks.count, 2)
        XCTAssertEqual(seeks.last ?? -1, 0.60, accuracy: 0.000_001)
    }

    func testIncrement_nearTheChapterEnd_clampsToTheEnd() throws {
        let slider = try mountSlider(at: 0.99, chapterDuration: 600, forward: 30, back: 15)

        slider.object.accessibilityIncrement()
        host?.settle(0.1)

        XCTAssertEqual(seeks, [1.0])
    }

    func testDecrement_nearTheChapterStart_clampsToTheStart() throws {
        let slider = try mountSlider(at: 0.01, chapterDuration: 600, forward: 30, back: 15)

        slider.object.accessibilityDecrement()
        host?.settle(0.1)

        XCTAssertEqual(seeks, [0.0])
    }

    /// VoiceOver reads the value for the step's target straight away.
    func testIncrement_updatesTheSpokenValueToTheTarget() throws {
        let slider = try mountSlider(at: 0.5, chapterDuration: 600, forward: 30, back: 15)
        XCTAssertEqual(slider.object.accessibilityValue, "50%")

        slider.object.accessibilityIncrement()
        host?.settle(0.1)

        XCTAssertEqual(try liveSlider().object.accessibilityValue, "55%")
    }

    // MARK: - Hold while the seek lands (live playback binding)

    /// 3,600 s chapter: a 30 s step is under 1% of it. A stale playback tick
    /// from before the seek landed must not release the hold, so the spoken
    /// value stays on the target and the next swipe steps from the target.
    func testStaleTickBetweenSwipes_onALongChapter_keepsTheHoldSoStepsAccumulate() throws {
        let live = LivePosition(0.5)
        try mountLiveSlider(live, chapterDuration: 3_600)
        let first = 0.5 + 30.0 / 3_600

        try liveSlider().object.accessibilityIncrement()
        host?.settle(0.1)
        live.value = 0.500_1 // stale tick from the pre-seek position
        host?.settle(0.1)

        XCTAssertEqual(try liveSlider().object.accessibilityValue, Self.spoken(first),
                       "a stale tick must not pull the spoken value back to the old position")
        try liveSlider().object.accessibilityIncrement()
        host?.settle(0.1)

        XCTAssertEqual(seeks.count, 2)
        XCTAssertEqual(seeks.last ?? -1, first + 30.0 / 3_600, accuracy: 0.000_001,
                       "the second swipe must step from the first target")
    }

    /// Once playback reports the target, the hold releases and the slider
    /// follows the live value again.
    func testLiveTickAtTheTarget_releasesTheHold() throws {
        let live = LivePosition(0.5)
        try mountLiveSlider(live, chapterDuration: 3_600)
        let first = 0.5 + 30.0 / 3_600

        try liveSlider().object.accessibilityIncrement()
        host?.settle(0.1)
        live.value = first
        host?.settle(0.1)
        live.value = first + 0.02
        host?.settle(0.1)

        XCTAssertEqual(try liveSlider().object.accessibilityValue, Self.spoken(first + 0.02))
    }

    /// Only the latest commit's safety timer may release the hold: a swipe
    /// 1.2 s after another must still be held when the first timer fires.
    func testEarlierCommitsSafetyTimer_doesNotReleaseALaterHold() throws {
        let live = LivePosition(0.5)
        try mountLiveSlider(live, chapterDuration: 3_600)
        let second = 0.5 + 60.0 / 3_600

        try liveSlider().object.accessibilityIncrement()
        host?.settle(1.2)
        try liveSlider().object.accessibilityIncrement()
        host?.settle(1.1) // the first commit's 2 s timer has fired

        XCTAssertEqual(try liveSlider().object.accessibilityValue, Self.spoken(second))
    }

    // MARK: - Hold release rule

    /// A move of 2% or more keeps the 1% tolerance a drag always had.
    func testHoldReleases_afterALargeMove_usesTheOnePercentTolerance() {
        typealias S = PalaceSeekSliderView
        XCTAssertTrue(S.holdReleases(live: 0.595, target: 0.6, origin: 0.2))
        XCTAssertTrue(S.holdReleases(live: 0.609, target: 0.6, origin: 0.2))
        XCTAssertFalse(S.holdReleases(live: 0.58, target: 0.6, origin: 0.2))
        XCTAssertFalse(S.holdReleases(live: 0.2, target: 0.6, origin: 0.2))
    }

    /// A move under 2% narrows the tolerance to half the move, so a tick at
    /// the old position never counts as arrival.
    func testHoldReleases_afterASmallMove_needsTheLiveValueNearerTheTargetThanHalfTheMove() {
        typealias S = PalaceSeekSliderView
        let origin = 0.5, target = 0.5 + 30.0 / 3_600 // half the move is ~0.00417
        XCTAssertFalse(S.holdReleases(live: 0.500_1, target: target, origin: origin))
        XCTAssertFalse(S.holdReleases(live: target - 0.0045, target: target, origin: origin))
        XCTAssertTrue(S.holdReleases(live: target - 0.004, target: target, origin: origin))
        XCTAssertTrue(S.holdReleases(live: target, target: target, origin: origin))
    }

    /// A step clamped at a bound does not move; only an exact live match
    /// releases it, and otherwise the safety timer does.
    func testHoldReleases_whenTheCommitDidNotMove_releasesOnlyOnAnExactMatch() {
        typealias S = PalaceSeekSliderView
        XCTAssertTrue(S.holdReleases(live: 1, target: 1, origin: 1))
        XCTAssertFalse(S.holdReleases(live: 0.999, target: 1, origin: 1))
    }

    // MARK: - Step arithmetic

    func testSteppedPosition_convertsSecondsToAChapterFraction() {
        typealias S = PalaceSeekSliderView
        XCTAssertEqual(S.steppedPosition(from: 0.5, direction: .forward, stepSeconds: 30, chapterDuration: 600), 0.55, accuracy: 0.000_001)
        XCTAssertEqual(S.steppedPosition(from: 0.5, direction: .back, stepSeconds: 30, chapterDuration: 600), 0.45, accuracy: 0.000_001)
    }

    func testSteppedPosition_clampsToTheChapterBounds() {
        typealias S = PalaceSeekSliderView
        XCTAssertEqual(S.steppedPosition(from: 0.98, direction: .forward, stepSeconds: 30, chapterDuration: 600), 1)
        XCTAssertEqual(S.steppedPosition(from: 0.02, direction: .back, stepSeconds: 30, chapterDuration: 600), 0)
        XCTAssertEqual(S.steppedPosition(from: 1, direction: .forward, stepSeconds: 30, chapterDuration: 600), 1)
        XCTAssertEqual(S.steppedPosition(from: 0, direction: .back, stepSeconds: 30, chapterDuration: 600), 0)
    }

    /// Before the chapter length is known the step is 5% of the chapter,
    /// never a division by zero or a NaN seek.
    func testSteppedPosition_withUnknownChapterLength_usesTheFallbackFraction() {
        typealias S = PalaceSeekSliderView
        XCTAssertEqual(S.steppedPosition(from: 0.5, direction: .forward, stepSeconds: 30, chapterDuration: 0), 0.55, accuracy: 0.000_001)
        XCTAssertEqual(S.steppedPosition(from: 0.5, direction: .back, stepSeconds: 30, chapterDuration: .nan), 0.45, accuracy: 0.000_001)
        XCTAssertEqual(S.steppedPosition(from: 0.5, direction: .forward, stepSeconds: 30, chapterDuration: -10), 0.55, accuracy: 0.000_001)
    }

    /// A step longer than the chapter lands on the bound, not past it.
    func testSteppedPosition_withAStepLongerThanTheChapter_landsOnTheBound() {
        typealias S = PalaceSeekSliderView
        XCTAssertEqual(S.steppedPosition(from: 0.1, direction: .forward, stepSeconds: 60, chapterDuration: 20), 1)
        XCTAssertEqual(S.steppedPosition(from: 0.9, direction: .back, stepSeconds: 60, chapterDuration: 20), 0)
    }

    // MARK: - Helpers

    private func mountSlider(
        at position: Double,
        chapterDuration: TimeInterval = 600,
        forward: Int = 30,
        back: Int = 30
    ) throws -> AXAuditElement {
        let view = PalaceSeekSliderView(
            value: .constant(position),
            onChange: { [unowned self] in self.seeks.append($0) },
            chapterDuration: chapterDuration,
            forwardStepSeconds: forward,
            backStepSeconds: back
        )
        .accessibilityLabel("Playback position")
        .padding()

        let host = AccessibilityAuditHost(UIHostingController(rootView: view))
        self.host = host
        return try liveSlider()
    }

    /// Re-reads the slider's accessibility element after a state change.
    private func liveSlider() throws -> AXAuditElement {
        let window = try XCTUnwrap(host?.window)
        return try XCTUnwrap(AccessibilityTraversalAudit.traverse(window)
            .first { $0.label == "Playback position" }, "the slider must be reachable")
    }

    /// A playback position the test can publish ticks on, like the player's
    /// chapter progress. The binding's setter is a no-op, as in production.
    private final class LivePosition: ObservableObject {
        @Published var value: Double
        init(_ value: Double) { self.value = value }
    }

    private struct LiveSliderHarness: View {
        @ObservedObject var live: LivePosition
        let chapterDuration: TimeInterval
        let onChange: (Double) -> Void

        var body: some View {
            PalaceSeekSliderView(
                value: Binding(get: { live.value }, set: { _ in }),
                onChange: onChange,
                chapterDuration: chapterDuration,
                forwardStepSeconds: 30,
                backStepSeconds: 30,
                spokenValue: { PalaceSeekSliderAccessibilityTests.spoken($0) }
            )
            .accessibilityLabel("Playback position")
            .padding()
        }
    }

    /// Four decimals, so a sub-1% difference is audible to the assertion.
    nonisolated static func spoken(_ fraction: Double) -> String {
        String(format: "%.4f", fraction)
    }

    private func mountLiveSlider(_ live: LivePosition, chapterDuration: TimeInterval) throws {
        let harness = LiveSliderHarness(live: live, chapterDuration: chapterDuration,
                                        onChange: { [unowned self] in self.seeks.append($0) })
        host = AccessibilityAuditHost(UIHostingController(rootView: harness))
        _ = try liveSlider()
    }
}
