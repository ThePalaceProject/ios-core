//
//  ReaderNavBarStateSyncTests.swift
//  PalaceTests
//
//  The reader tracks navigation-bar visibility in `navigationBarHidden` and
//  renders it through `updateNavigationBar()`. The tracked value is what the
//  next tap toggles, so a path that moves the bar without moving the tracked
//  value leaves the toggle computing from a premise the screen no longer
//  matches, and the patron is left with a title and no Back control until a
//  second tap. `navigationBarShouldHide` and `overlayLabelsHidden` between them
//  guarantee one of the two is always on screen; these tests pin that pairing
//  and guard the EPUB controller against writing the bar directly again.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// The reader's nav-bar state, rendered by the production rule.
///
/// `tracked` is `navigationBarHidden`; `barIsHidden` is what the navigation
/// controller shows. `render()` is `updateNavigationBar()` — it calls the real
/// `navigationBarShouldHide`, so these tests fail when that rule changes.
private final class NavBarStateModel {
    private(set) var tracked: Bool
    private(set) var barIsHidden: Bool
    /// Rendered, not computed: the chrome's alpha only moves when something
    /// calls `updateOverlayLabelsVisibility`, so a path that renders the bar and
    /// forgets the chrome leaves this stale. That is the state these tests care
    /// about, and a computed property could not express it.
    private(set) var chromeVisibleOnScreen: Bool
    let voiceOverRunning: Bool

    init(tracked: Bool = true, voiceOverRunning: Bool = false) {
        self.tracked = tracked
        self.voiceOverRunning = voiceOverRunning
        self.barIsHidden = TPPBaseReaderViewController.navigationBarShouldHide(
            navigationBarHidden: tracked, voiceOverRunning: voiceOverRunning)
        self.chromeVisibleOnScreen = !TPPBaseReaderViewController.overlayLabelsHidden(
            navigationBarHidden: tracked, voiceOverRunning: voiceOverRunning)
    }

    /// `toggleNavigationBar()`: didSet renders the bar, then the method renders
    /// the chrome.
    func toggle() {
        tracked.toggle()
        render()
    }

    /// `resetNavigationBarToHidden()`: set the tracked value, then render
    /// unconditionally — `didSet` does not fire when it is already `true`.
    func resetToHidden() {
        tracked = true
        render()
    }

    /// What `viewWillAppear` used to do: move the bar, leave the tracked value.
    func hideBarWithoutTracking() {
        barIsHidden = true
    }

    /// The bar showing while the tracked value says hidden — a first appearance
    /// inside a navigation controller that is still showing its own bar.
    func showBarWithoutTracking() {
        barIsHidden = false
    }

    /// `updateNavigationBar()`.
    private func renderBar() {
        barIsHidden = TPPBaseReaderViewController.navigationBarShouldHide(
            navigationBarHidden: tracked, voiceOverRunning: voiceOverRunning)
    }

    /// `updateOverlayLabelsVisibility()`.
    private func renderChrome() {
        chromeVisibleOnScreen = !TPPBaseReaderViewController.overlayLabelsHidden(
            navigationBarHidden: tracked, voiceOverRunning: voiceOverRunning)
    }

    private func render() {
        renderBar()
        renderChrome()
    }

    /// A reset that moves the bar and forgets the chrome — what the first
    /// version of `resetNavigationBarToHidden` did.
    func resetRenderingOnlyTheBar() {
        tracked = true
        renderBar()
    }

    var overlayChromeVisible: Bool { chromeVisibleOnScreen }

    /// Back lives in the navigation bar. The reader's own left-edge swipe is
    /// consumed by the page-turn gesture, so this is the only exit.
    var backControlReachable: Bool { !barIsHidden }
}

@MainActor
final class ReaderNavBarStateSyncTests: XCTestCase {

    // MARK: - The production rule, every cell

    func testNavigationBarShouldHideCoversTheWholeTable() {
        let cases: [(tracked: Bool, voiceOver: Bool, hide: Bool)] = [
            (true,  false, true),   // immersive reading: the bar is away
            (false, false, false),  // the patron tapped it in
            (true,  true,  false),  // VoiceOver keeps the bar regardless
            (false, true,  false),
        ]
        for c in cases {
            XCTAssertEqual(
                TPPBaseReaderViewController.navigationBarShouldHide(
                    navigationBarHidden: c.tracked, voiceOverRunning: c.voiceOver),
                c.hide,
                "tracked=\(c.tracked) voiceOver=\(c.voiceOver)")
        }
    }

    /// The invariant the two rules exist to keep: the patron is never left with
    /// neither the immersive chrome nor the navigation bar. A screen with
    /// neither has no title, no position and no Back.
    func testEveryCellLeavesThePatronEitherChromeOrTheBar() {
        for tracked in [true, false] {
            for voiceOver in [true, false] {
                let m = NavBarStateModel(tracked: tracked, voiceOverRunning: voiceOver)
                XCTAssertTrue(
                    m.overlayChromeVisible || m.backControlReachable,
                    "tracked=\(tracked) voiceOver=\(voiceOver) shows neither the "
                    + "overlay chrome nor the navigation bar")
            }
        }
    }

    func testTrackedValueAndBarAgreeAfterEveryToggle() {
        let m = NavBarStateModel()
        for i in 0..<6 {
            m.toggle()
            XCTAssertEqual(m.barIsHidden,
                           TPPBaseReaderViewController.navigationBarShouldHide(
                            navigationBarHidden: m.tracked, voiceOverRunning: false),
                           "toggle \(i) left the bar disagreeing with the tracked value")
        }
    }

    func testBackIsReachableAfterOneTapFromTheImmersiveState() {
        let m = NavBarStateModel()
        m.toggle()
        XCTAssertTrue(m.backControlReachable, "one tap must reveal the navigation bar")
    }

    // MARK: - What the untracked write cost

    /// The reader reappears with the bar showing, the bar is hidden behind the
    /// tracked value's back, and the next tap no longer reveals it.
    func testTapAfterAnUntrackedHideFailsToRevealTheBar() {
        let m = NavBarStateModel()
        m.toggle()                        // bar shown, tracked == false
        XCTAssertTrue(m.backControlReachable)

        m.hideBarWithoutTracking()        // the old viewWillAppear write

        m.toggle()                        // the patron taps for the bar
        XCTAssertFalse(
            m.backControlReachable,
            "this test records the cost of the untracked write; if the bar is now "
            + "reachable the model no longer reproduces it")
        XCTAssertTrue(
            m.overlayChromeVisible,
            "the tap faded the immersive chrome in — a title with no Back is what "
            + "the patron was left looking at")
    }

    /// A second tap does recover, so the cost is a wasted tap and a confusing
    /// screen, not a reader the patron can never leave. Stated so no later
    /// reading of this file over-claims the symptom.
    func testASecondTapRecoversFromTheUntrackedHide() {
        let m = NavBarStateModel()
        m.toggle()
        m.hideBarWithoutTracking()
        m.toggle()
        m.toggle()
        XCTAssertTrue(m.backControlReachable,
                      "the drift costs one tap; it does not trap the patron")
    }

    /// The write also contradicted the VoiceOver exemption: it hid the bar for a
    /// patron for whom `navigationBarShouldHide` returns false in every cell.
    func testUnderVoiceOverTheRuleNeverHidesTheBarThatTheWriteHid() {
        for tracked in [true, false] {
            XCTAssertFalse(
                TPPBaseReaderViewController.navigationBarShouldHide(
                    navigationBarHidden: tracked, voiceOverRunning: true),
                "VoiceOver must keep the bar; tracked=\(tracked)")
        }
        let m = NavBarStateModel(voiceOverRunning: true)
        XCTAssertTrue(m.backControlReachable)
        m.hideBarWithoutTracking()
        XCTAssertFalse(m.backControlReachable,
                       "the untracked write takes the bar away under VoiceOver, "
                       + "which the rule never does")
    }

    // MARK: - The governed reset

    func testGovernedResetLeavesTheNextTapWorking() {
        let m = NavBarStateModel()
        m.toggle()                        // bar shown
        m.resetToHidden()                 // what viewWillAppear does now

        XCTAssertTrue(m.barIsHidden)
        m.toggle()
        XCTAssertTrue(m.backControlReachable,
                      "after a governed reset a single tap must reveal the bar")
    }

    /// The reset must render even when the tracked value is already `true` —
    /// `didSet` does not fire then, and that is the first-appearance case.
    func testGovernedResetRendersEvenWhenTheValueIsUnchanged() {
        let m = NavBarStateModel()        // tracked already true
        m.showBarWithoutTracking()
        m.resetToHidden()
        XCTAssertTrue(m.barIsHidden,
                      "reset did not hide the bar because the tracked value had "
                      + "not changed")
    }

    /// Under VoiceOver the reset must leave the bar in place.
    func testGovernedResetKeepsTheBarUnderVoiceOver() {
        let m = NavBarStateModel(voiceOverRunning: true)
        m.resetToHidden()
        XCTAssertTrue(m.backControlReachable,
                      "the reset hid the bar under VoiceOver, which is the "
                      + "behaviour it replaced")
    }

    /// A reset that renders only the bar leaves the patron with neither: the
    /// chrome faded out when the bar was tapped in, and nothing else brings it
    /// back. This is the combination the two rules exist to rule out.
    func testAResetThatRendersOnlyTheBarLeavesThePatronWithNeither() {
        let m = NavBarStateModel()
        m.toggle()                        // bar in, chrome faded out
        XCTAssertFalse(m.overlayChromeVisible)
        XCTAssertTrue(m.backControlReachable)

        m.resetRenderingOnlyTheBar()

        XCTAssertFalse(m.backControlReachable)
        XCTAssertFalse(
            m.overlayChromeVisible,
            "this records why the reset renders the chrome as well; if the chrome "
            + "is visible here the model no longer reproduces the omission")
    }

    /// The reset as shipped: both are rendered, so the patron keeps the chrome.
    func testGovernedResetBringsTheChromeBackWithTheBar() {
        let m = NavBarStateModel()
        m.toggle()
        m.resetToHidden()
        XCTAssertTrue(m.overlayChromeVisible || m.backControlReachable,
                      "the reset left the patron with neither chrome nor bar")
        XCTAssertTrue(m.overlayChromeVisible,
                      "the immersive chrome is what replaces the bar")
    }

    // MARK: - Production wiring

    /// RED if a direct `setNavigationBarHidden` returns to the EPUB controller.
    /// `updateNavigationBar` is the single writer; any other caller can
    /// reintroduce the drift without failing a test that only exercises toggling.
    func testEPUBViewControllerDoesNotWriteTheNavigationBarDirectly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Reader2
            .deletingLastPathComponent()      // PalaceTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Palace/Reader2/UI/TPPEPUBViewController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let offenders = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { _, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && t.contains("setNavigationBarHidden")
            }
            .map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

        XCTAssertTrue(
            offenders.isEmpty,
            "TPPEPUBViewController writes the navigation bar directly, bypassing "
            + "navigationBarHidden. Use resetNavigationBarToHidden() instead:\n"
            + offenders.joined(separator: "\n"))
    }

    /// The reset must render the bar AND the chrome. Asserted against the source
    /// because the controller needs a Publication and a navigator to build, so
    /// there is no seam to drive the real method from a unit test. Named as a
    /// structural guard rather than a behavioural one.
    func testTheGovernedResetRendersBothTheBarAndTheChrome() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Palace/Reader2/UI/TPPBaseReaderViewController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        guard let start = source.range(of: "func resetNavigationBarToHidden(") else {
            return XCTFail("resetNavigationBarToHidden is gone; the EPUB controller "
                           + "has nothing governed to call")
        }
        let body = source[start.upperBound...].prefix(600)
        XCTAssertTrue(body.contains("navigationBarHidden = true"),
                      "the reset no longer sets the tracked value, so the next tap "
                      + "still toggles from a stale premise")
        XCTAssertTrue(body.contains("updateNavigationBar("),
                      "the reset relies on didSet, which does not fire when the "
                      + "value is already true")
        XCTAssertTrue(body.contains("updateOverlayLabelsVisibility("),
                      "the reset hides the bar without bringing the chrome back, "
                      + "leaving the patron with neither")
    }

    /// The guard above can only find a violation if it can read the file at all.
    func testTheWiringGuardIsLookingAtTheRealFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Palace/Reader2/UI/TPPEPUBViewController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("class TPPEPUBViewController"),
                      "the guard is reading something that is not the EPUB controller")
        XCTAssertTrue(source.contains("resetNavigationBarToHidden()"),
                      "viewWillAppear no longer routes through the governed reset")
    }
}
