//
//  ReaderNavBarVoiceOverTests.swift
//  PalaceTests
//
//  PP-4326 follow-up (3.0.2 hotfix). Product requirement:
//
//  > When a user opens a book with VoiceOver already running, the reader
//  > navbar (back / TOC / bookmark / settings) must auto-present so the
//  > user can navigate the reader without first having to tap the screen
//  > to surface a hidden toolbar.
//
//  Background. `TPPBaseReaderViewController.updateNavigationBar()` does
//  the right thing — `let hidden = navigationBarHidden &&
//  !UIAccessibility.isVoiceOverRunning` keeps the navbar visible when VO
//  is running. But the equivalent call at viewDidLoad time (via
//  `setupView` → `updateViewsForVoiceOver(isRunning:)`) is too early: the
//  view controller hasn't yet been integrated into the navigation stack,
//  so `navigationController?.setNavigationBarHidden(false, animated:)`
//  has no effect. By the time `viewDidAppear` fires, the integration is
//  done — re-applying `updateNavigationBar` there ensures VoiceOver-on
//  entry to a book lands with the navbar visible.
//
//  Reader2's underlying `UIViewController` plumbing is not testable in
//  unit tests without instantiating Readium publications, so this test
//  is a source-level sentinel (same pattern as PP-3980's test in
//  CatalogLaneRowViewAccessibilityTests).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class ReaderNavBarVoiceOverTests: XCTestCase {

    /// Product requirement: `viewDidAppear` in `TPPBaseReaderViewController`
    /// MUST call `updateNavigationBar` when VoiceOver is running. Without
    /// that re-application, the navbar's initial visibility (set during
    /// viewDidLoad) is silently discarded by the navigation controller's
    /// late integration and the user lands in the reader with no visible
    /// nav affordance.
    func testViewDidAppear_reAppliesNavBarVisibilityWhenVoiceOverIsRunning() throws {
        let source = try Self.source(for: "Palace/Reader2/UI/TPPBaseReaderViewController.swift")

        // 1. viewDidAppear exists.
        XCTAssertTrue(
            source.contains("override func viewDidAppear"),
            "TPPBaseReaderViewController must override viewDidAppear (PP-4326 navbar follow-up)."
        )

        // 2. viewDidAppear must check UIAccessibility.isVoiceOverRunning
        // and call updateNavigationBar(...) when true. Extract the
        // viewDidAppear body and assert both calls live there.
        guard let viewDidAppearRange = source.range(of: "override func viewDidAppear"),
              let nextOverrideRange = source.range(
                  of: "override func ",
                  range: viewDidAppearRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Could not isolate the viewDidAppear method body in TPPBaseReaderViewController.swift")
            return
        }
        let viewDidAppearBody = String(source[viewDidAppearRange.lowerBound..<nextOverrideRange.lowerBound])

        XCTAssertTrue(
            viewDidAppearBody.contains("UIAccessibility.isVoiceOverRunning"),
            "viewDidAppear must check UIAccessibility.isVoiceOverRunning to decide whether to re-apply the navbar visibility (PP-4326 navbar follow-up)."
        )
        XCTAssertTrue(
            viewDidAppearBody.contains("updateNavigationBar"),
            "viewDidAppear must call updateNavigationBar(...) when VoiceOver is running so the reader navbar auto-presents on book open (PP-4326 navbar follow-up)."
        )
    }

    /// The existing accessibility-aware navbar logic in
    /// `updateNavigationBar` must be preserved — without this guard,
    /// future refactors could remove the
    /// `&& !UIAccessibility.isVoiceOverRunning` clause and the product
    /// requirement silently regresses.
    func testUpdateNavigationBar_keepsNavBarVisibleWhenVoiceOverIsRunning() throws {
        let source = try Self.source(for: "Palace/Reader2/UI/TPPBaseReaderViewController.swift")
        XCTAssertTrue(
            source.contains("navigationBarHidden && !UIAccessibility.isVoiceOverRunning"),
            "updateNavigationBar must compute hidden as `navigationBarHidden && !UIAccessibility.isVoiceOverRunning` so the navbar stays visible while VoiceOver is running (PP-4326 navbar follow-up)."
        )
    }

    // MARK: - Helpers

    private static func source(for repoRelativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // Reader
            .deletingLastPathComponent()        // PalaceTests
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent(repoRelativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
