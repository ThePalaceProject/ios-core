//
//  ReaderLetterboxTapGateTests.swift
//  PalaceTests
//
//  The navigator's web view is inset inside its container by a fixed 100pt top
//  and 50pt bottom letterbox, and the web view owns every tap gesture, so a tap
//  in a letterbox reached no handler at all (PP-5394). These resolve each tap
//  through real UIKit hit-testing, so a layout where the scrubber or the web
//  view covers the point is distinguishable from bare letterbox.
//

import XCTest
import UIKit
@testable import Palace

@MainActor
final class ReaderLetterboxTapGateTests: XCTestCase {

    private var container: UIView!
    private var navigatorView: UIView!
    private var scrubber: UIView!

    /// Mirrors the reader's own layout: container full-bleed, web view inset by
    /// 100pt at the top and 50pt at the bottom, scrubber in the bottom letterbox.
    override func setUp() {
        super.setUp()
        container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        navigatorView = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 650))
        scrubber = UIView(frame: CGRect(x: 20, y: 760, width: 360, height: 30))
        container.addSubview(navigatorView)
        container.addSubview(scrubber)
    }

    override func tearDown() {
        container = nil
        navigatorView = nil
        scrubber = nil
        super.tearDown()
    }

    private func verdictForTap(at point: CGPoint) -> Bool {
        let touched = container.hitTest(point, with: nil)
        return ReaderLetterboxTapGate.isLetterboxTap(touchedView: touched, container: container)
    }

    /// The reported defect: this strip is where the toolbar's controls sit, so
    /// a tap here must reach the chrome toggle instead of being swallowed.
    func testTapInTopLetterbox_isLetterboxTap() {
        XCTAssertTrue(verdictForTap(at: CGPoint(x: 200, y: 50)),
                      "A tap in the 100pt top letterbox must toggle the chrome")
    }

    /// Page content keeps its own tap handling — paging and the web view's own
    /// toggle — so routing it here too would toggle twice and cancel out.
    func testTapOnPageContent_isNotLetterboxTap() {
        XCTAssertFalse(verdictForTap(at: CGPoint(x: 200, y: 400)),
                       "A tap on the web view belongs to the navigator, not the gate")
    }

    /// The scrubber lives inside the bottom letterbox; stealing its touches
    /// would break seeking.
    func testTapOnChapterScrubber_isNotLetterboxTap() {
        XCTAssertFalse(verdictForTap(at: CGPoint(x: 200, y: 775)),
                       "A tap on the chapter scrubber belongs to the scrubber")
    }

    func testTapInBottomLetterboxBesideScrubber_isLetterboxTap() {
        XCTAssertTrue(verdictForTap(at: CGPoint(x: 5, y: 755)),
                      "Bare bottom letterbox must toggle the chrome")
    }

    /// `hitTest` returns nil outside the container; the gate must not read that
    /// as a letterbox tap.
    func testTapOutsideContainer_isNotLetterboxTap() {
        XCTAssertFalse(verdictForTap(at: CGPoint(x: 200, y: 900)),
                       "A point outside the container is not a letterbox tap")
    }
}
