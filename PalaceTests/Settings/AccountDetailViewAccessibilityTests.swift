//
//  AccountDetailViewAccessibilityTests.swift
//  PalaceTests
//
//  VoiceOver duplication guard for the HelpSpot 17923 caption fix.
//  The caption Text ("Tap here to enter your Barcode or Username")
//  exists purely for sighted patrons who perceive the .placeholderText
//  ghost as "disabled." VoiceOver users already hear the field label
//  via .accessibilityLabel on the underlying TextField, so the caption
//  must be marked .accessibilityHidden(true) — otherwise VoiceOver
//  announces the field name twice ("Tap here to enter your Barcode or
//  Username, Barcode or Username, text field").
//
//  These tests pin that contract by introspecting the AccountDetailView
//  source file directly. We assert the literal `.accessibilityHidden(true)`
//  modifier follows the caption Text construction in both barcodeInputCell
//  and pinInputCell. A regression that removes the modifier — even a
//  well-meaning "VoiceOver should read the caption too" PR — will fail
//  this test loudly.
//

import XCTest
@testable import Palace

final class AccountDetailViewAccessibilityTests: XCTestCase {

    // MARK: - Source-level a11y contract guards
    //
    // We deliberately read the source file rather than constructing the
    // view, because:
    //   1. Building a full AccountDetailView requires AppContainer +
    //      keychain entitlement, neither available on CI.
    //   2. SwiftUI's accessibilityHidden modifier is erased into the
    //      runtime accessibility tree in a way that's hard to introspect
    //      from a unit test (UIHostingController collapses the SwiftUI
    //      tree into platform a11y elements).
    //   3. The mutation we care about catching is a single-line edit in
    //      source — removing or flipping the .accessibilityHidden(true)
    //      modifier. Source-level pinning kills that mutant directly.

    private var sourceText: String {
        guard let path = locateSourceFile() else {
            XCTFail("Could not locate AccountDetailView.swift in the project tree.")
            return ""
        }
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("Could not read AccountDetailView.swift at \(path).")
            return ""
        }
        return data
    }

    func testBarcodeInputCell_captionIsAccessibilityHidden() {
        let body = sliceBody(of: "private var barcodeInputCell", length: 1500)
        XCTAssertTrue(
            body.contains("tapToEnter"),
            "barcodeInputCell must render the tapToEnter caption — patrons report the placeholder as 'disabled'."
        )
        XCTAssertTrue(
            body.contains(".accessibilityHidden(true)"),
            "barcodeInputCell caption must be .accessibilityHidden(true). Without it, VoiceOver announces the field name twice."
        )
    }

    func testPinInputCell_captionIsAccessibilityHidden() {
        let body = sliceBody(of: "private var pinInputCell", length: 2200)
        XCTAssertTrue(
            body.contains("tapToEnter"),
            "pinInputCell must render the tapToEnter caption — patrons report the placeholder as 'disabled'."
        )
        XCTAssertTrue(
            body.contains(".accessibilityHidden(true)"),
            "pinInputCell caption must be .accessibilityHidden(true). Without it, VoiceOver announces 'PIN' twice."
        )
    }

    /// Returns up to `length` characters of source following the first
    /// occurrence of `marker`. Returns empty string + XCTFail when the
    /// marker isn't present (refactor probably renamed the function).
    private func sliceBody(of marker: String, length: Int) -> String {
        let src = sourceText
        guard let markerRange = src.range(of: marker) else {
            XCTFail("\(marker) not found — refactor may have renamed it. Update this test.")
            return ""
        }
        let start = markerRange.lowerBound
        let end = src.index(start, offsetBy: length, limitedBy: src.endIndex) ?? src.endIndex
        return String(src[start..<end])
    }

    func testBothInputCells_preserveAccessibilityLabelOnUnderlyingField() {
        let src = sourceText
        // The TextField/SecureField .accessibilityLabel(...) calls must
        // remain intact — they are what VoiceOver actually announces.
        // Stripping them while keeping the caption hidden would leave
        // VoiceOver patrons with NO field-name announcement at all.
        XCTAssertTrue(
            src.contains(".accessibilityLabel(viewModel.businessLogic.selectedAuthentication?.patronIDLabel ?? DisplayStrings.barcodeOrUsername)"),
            "barcode TextField must keep its existing accessibilityLabel — this is what VoiceOver actually announces."
        )
        XCTAssertTrue(
            src.contains(".accessibilityLabel(pinLabel)"),
            "PIN field must keep its accessibilityLabel — this is what VoiceOver actually announces."
        )
    }

    // MARK: - Helpers

    /// Walks up from the test bundle to find the project root, then
    /// locates AccountDetailView.swift. Avoids hardcoding a workspace
    /// path so the test passes whether run from CI, a worktree, or a
    /// local clone.
    private func locateSourceFile() -> String? {
        let candidate = "Palace/Settings/AccountDetailView.swift"
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let probe = dir.appendingPathComponent(candidate).path
            if FileManager.default.fileExists(atPath: probe) {
                return probe
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
