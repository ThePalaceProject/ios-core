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
}
