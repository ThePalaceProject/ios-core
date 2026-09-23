//
//  CatalogViewLibraryIconTests.swift
//  PalaceTests
//
//  PP-4821 — the top-left Palace icon on the catalog screen is static branding,
//  not a library switcher. Library switching now lives solely in Settings.
//
//  These are source-level contract guards, the same technique (and for the same
//  reason) as the CatalogView guards in CatalogViewContinueRowsIntegrationTests:
//  a SwiftUI `ToolbarContent` tree has no runtime-introspectable seam in this
//  project (no ViewInspector), so we pin the *shape* of the leading toolbar item
//  against the production source. If a future change re-wires the icon back into
//  a tappable switcher, these fail loudly instead of silently regressing the
//  single-entry-point decision.
//

import XCTest

final class CatalogViewLibraryIconTests: XCTestCase {

    private func catalogViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // CatalogUI
            .deletingLastPathComponent()        // PalaceTests
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent("Palace/CatalogUI/Views/CatalogView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The leading (top-left) toolbar item renders the Palace branding icon as a
    /// plain, non-interactive, VoiceOver-hidden image — NOT a Button, and it
    /// presents no library-picker action sheet.
    ///
    /// Mutates: re-wrapping the icon in a `Button`, restoring the `.actionSheet`,
    /// or dropping `.accessibilityHidden(true)` each fails a distinct assertion.
    func testCatalogLeadingIcon_isStaticBranding_notASwitcher() throws {
        let source = try catalogViewSource()

        // Isolate the .navigationBarLeading toolbar item so the assertions can't
        // be satisfied by (or falsely tripped by) the trailing search Button.
        guard let leadingStart = source.range(of: "placement: .navigationBarLeading)"),
              let trailingStart = source.range(of: "placement: .navigationBarTrailing)") else {
            return XCTFail("CatalogView toolbar MUST declare both a leading and a trailing item")
        }
        let leadingBlock = String(source[leadingStart.upperBound..<trailingStart.lowerBound])

        XCTAssertTrue(leadingBlock.contains("ImageProviders.MyBooksView.myLibraryIcon"),
                      "The leading toolbar item MUST still render the Palace branding icon (no visual regression to the header)")
        XCTAssertTrue(leadingBlock.contains("accessibilityHidden(true)"),
                      "The branding icon MUST stay hidden from VoiceOver — no button trait, no switching announcement")
        // Match the control *constructors*, not the bare words — the explanatory
        // comment in this toolbar item legitimately mentions "Button"/"tap".
        XCTAssertFalse(leadingBlock.contains("Button("),
                       "The Palace icon MUST NOT be a Button — library switching lives in Settings now (PP-4821)")
        XCTAssertFalse(leadingBlock.contains(".actionSheet("),
                       "Tapping the Palace icon MUST NOT open a library-picker action sheet")
        XCTAssertFalse(leadingBlock.contains(".onTapGesture"),
                       "The Palace icon MUST NOT carry a tap gesture")
    }

    /// The switcher's supporting machinery is gone entirely, not merely
    /// disconnected — so a stray reference can't quietly re-arm it.
    func testCatalogView_hasNoLibrarySwitcherMachinery() throws {
        let source = try catalogViewSource()

        XCTAssertFalse(source.contains("showAccountDialog"),
                       "The library-switcher dialog state MUST be removed")
        XCTAssertFalse(source.contains("AccessibilityID.Catalog.accountButton"),
                       "The catalog account-switcher accessibility identifier MUST be removed")
        XCTAssertFalse(source.contains("libraryPicker"),
                       "The catalog library-picker action sheet MUST be removed")
    }
}
