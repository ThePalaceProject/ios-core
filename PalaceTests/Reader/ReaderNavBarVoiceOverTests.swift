//  ReaderNavBarVoiceOverTests.swift
//
//  PP-4326 (3.0.2): opening a book with VoiceOver running must show the reader
//  navbar without a tap. `updateNavigationBar()` keeps the bar visible under VO,
//  but its viewDidLoad-time call runs before the controller is in the navigation
//  stack, so `setNavigationBarHidden(false,...)` has no effect; it is re-applied
//  in `viewDidAppear`. Reader2's controller cannot be built without a Readium
//  publication, so this is a source-level sentinel (same pattern as PP-3980 in
//  CatalogLaneRowViewAccessibilityTests).

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
