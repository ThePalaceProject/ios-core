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

    /// The accessibility-aware navbar rule must be preserved: while VoiceOver
    /// runs, the bar stays visible whatever the tracked value says, because it
    /// carries the only reachable Back control. Asserted against the rule rather
    /// than against the text of the expression — a source match would also fail
    /// for a rename that changed nothing (PP-4326 navbar follow-up).
    func testNavigationBarShouldHide_keepsNavBarVisibleWhenVoiceOverIsRunning() {
        for tracked in [true, false] {
            XCTAssertFalse(
                TPPBaseReaderViewController.navigationBarShouldHide(
                    navigationBarHidden: tracked, voiceOverRunning: true),
                "the navbar must stay visible while VoiceOver is running; tracked=\(tracked)"
            )
        }
        XCTAssertTrue(
            TPPBaseReaderViewController.navigationBarShouldHide(
                navigationBarHidden: true, voiceOverRunning: false),
            "with VoiceOver off the bar still hides for immersive reading"
        )
    }

    /// And `updateNavigationBar` must route through that rule, so the assertion
    /// above is about the code the reader actually runs.
    func testUpdateNavigationBar_routesThroughTheSharedRule() throws {
        let source = try Self.source(for: "Palace/Reader2/UI/TPPBaseReaderViewController.swift")
        guard let start = source.range(of: "func updateNavigationBar(") else {
            return XCTFail("updateNavigationBar is gone from TPPBaseReaderViewController")
        }
        let body = source[start.upperBound...].prefix(400)
        XCTAssertTrue(
            body.contains("navigationBarShouldHide("),
            "updateNavigationBar computes the bar's visibility some other way, so "
            + "navigationBarShouldHide no longer describes what the reader does "
            + "(PP-4326 navbar follow-up)."
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
