//  WebAuthPresentationAnchorTests.swift
//
//  `UIApplication.webAuthPresentationAnchor` resolves the anchor for all three
//  OIDC re-auth paths. Pinned: the window filter, which requires a visible,
//  `.normal`-level window with a root view controller. The original bug was a
//  fallback that handed iOS an unusable window. Real `UIWindow`s are used; a
//  fresh `UIWindow()` starts hidden.

import XCTest
import UIKit
@testable import Palace

final class WebAuthPresentationAnchorTests: XCTestCase {

    /// Calls PRODUCTION, not a local copy of the predicate — a copy would stay
    /// green when a clause is deleted from production.
    private func isUsableAnchor(_ window: UIWindow) -> Bool {
        UIApplication.isUsableWebAuthAnchor(window)
    }

    private func makeWindow(hidden: Bool = false,
                            level: UIWindow.Level = .normal,
                            withRoot: Bool = true) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.isHidden = hidden
        window.windowLevel = level
        window.rootViewController = withRoot ? UIViewController() : nil
        return window
    }

    /// The shape a real app window has — the only one worth anchoring to.
    func testUsableWindow_isAccepted() {
        XCTAssertTrue(isUsableAnchor(makeWindow()),
                      "A visible, normal-level window with a root view controller is a valid anchor")
    }

    /// A fresh `UIWindow()` is hidden by default, so "just take windows.first"
    /// can hand iOS an invisible window.
    func testHiddenWindow_isRejected() {
        XCTAssertFalse(isUsableAnchor(makeWindow(hidden: true)),
                       "A hidden window cannot host a sheet — this is what an unfiltered windows.first returns")
    }

    /// Keyboard and alert windows sit above `.normal`.
    func testAboveNormalLevelWindow_isRejected() {
        XCTAssertFalse(isUsableAnchor(makeWindow(level: .alert)),
                       "Keyboard/alert-level windows must not be used as the presentation anchor")
        XCTAssertFalse(isUsableAnchor(makeWindow(level: UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1))),
                       "Any window above .normal is chrome, not a host")
    }

    /// A window with no root view controller has nothing to present from.
    func testRootlessWindow_isRejected() {
        XCTAssertFalse(isUsableAnchor(makeWindow(withRoot: false)),
                       "A window with no rootViewController cannot present")
    }

    /// All three rejection reasons are independent — pinned together so
    /// dropping any single clause fails.
    func testEachClauseIsLoadBearing() {
        XCTAssertFalse(isUsableAnchor(makeWindow(hidden: true, level: .normal, withRoot: true)),
                       "visibility clause")
        XCTAssertFalse(isUsableAnchor(makeWindow(hidden: false, level: .alert, withRoot: true)),
                       "level clause")
        XCTAssertFalse(isUsableAnchor(makeWindow(hidden: false, level: .normal, withRoot: false)),
                       "root-view-controller clause")
    }
}
