//
//  WebAuthPresentationAnchorTests.swift
//  PalaceTests
//
//  `UIApplication.webAuthPresentationAnchor` is the shared anchor resolver for
//  all three OIDC re-auth paths. I initially claimed it was untestable and
//  covered it with a source lint; SoD review disproved that — real `UIWindow`s
//  drive the filter fine, and only the *scene lookup* would need a fake. It also
//  pointed out that a fresh `UIWindow()` defaults to `isHidden == true`, which a
//  real test catches and a lint never would.
//
//  What is pinned here is the FILTER, which is the part with logic: a candidate
//  window must be visible, at `.normal` level, and have a root view controller.
//  Anchoring to a keyboard, hidden, or rootless window fails differently rather
//  than better — and the original bug was precisely a fallback that handed iOS
//  an unusable window.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import UIKit
@testable import Palace

final class WebAuthPresentationAnchorTests: XCTestCase {

    /// Calls PRODUCTION. The first version of this file declared its own copy
    /// of the predicate, so deleting a clause from production left all five
    /// tests green — including `testEachClauseIsLoadBearing`, whose name claimed
    /// the opposite. Two reviewers caught it independently.
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

    /// All three rejection reasons are independent — pinned together so a
    /// mutant that drops any single clause fails.
    func testEachClauseIsLoadBearing() {
        XCTAssertFalse(isUsableAnchor(makeWindow(hidden: true, level: .normal, withRoot: true)),
                       "visibility clause")
        XCTAssertFalse(isUsableAnchor(makeWindow(hidden: false, level: .alert, withRoot: true)),
                       "level clause")
        XCTAssertFalse(isUsableAnchor(makeWindow(hidden: false, level: .normal, withRoot: false)),
                       "root-view-controller clause")
    }
}
