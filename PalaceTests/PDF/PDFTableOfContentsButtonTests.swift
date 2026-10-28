//
//  PDFTableOfContentsButtonTests.swift
//  PalaceTests
//
//  The PDF reader's list icon is labelled Table of Contents and announces that
//  to VoiceOver, but it opened whatever the segmented picker had last selected
//  — page previews on every first tap, since that state starts at the first
//  case (PP-5404).
//
//  Driven through the control: the toolbar is mounted in a hosting controller
//  and the button activated as a VoiceOver double-tap does, so the button's
//  action is what the assertions observe. Asserting the destination constant on
//  its own cannot fail — the defect lived at the call site, which read
//  `pickerSelection` instead.
//

import SwiftUI
import XCTest
@testable import Palace

@MainActor
final class PDFTableOfContentsButtonTests: XCTestCase {

    private var host: AccessibilityAuditHost?
    private var metadata: MockPDFDocumentMetadata?
    private var mode: ReaderModeBox?

    override class func tearDown() {
        MainActor.assumeIsolated { AccessibilityRuntime.restore() }
        super.tearDown()
    }

    override func tearDown() {
        host?.tearDown()
        host = nil
        metadata = nil
        mode = nil
        super.tearDown()
    }

    // MARK: - The control labelled Table of Contents

    /// Tapping it opens the table of contents, from the reader's starting state
    /// — the first tap is the one the defect always got wrong, because
    /// `pickerSelection` starts at the page-previews case.
    func test_theTableOfContentsButton_opensTheTableOfContents() throws {
        try mountNavigation()

        try activate(labelled: Strings.Generic.tableOfContents)

        XCTAssertEqual(mode?.value, .toc,
                       "a control labelled Table of Contents must open the table of contents, not page previews")
    }

    /// It also moves the segmented picker, which replaces the button once a mode
    /// is showing, onto the matching segment — otherwise the picker highlights
    /// and announces Page Previews over table-of-contents content.
    func test_theTableOfContentsButton_leavesThePickerOnTheTableOfContentsSegment() throws {
        try mountNavigation()

        try activate(labelled: Strings.Generic.tableOfContents)

        settle(until: { self.segment(labelled: Strings.Generic.pagePreviewsTab) != nil },
               "the picker must replace the button once a mode is showing")
        let toc = try XCTUnwrap(segment(labelled: Strings.Generic.tableOfContents),
                                "the picker must carry a table-of-contents segment")
        let previews = try XCTUnwrap(segment(labelled: Strings.Generic.pagePreviewsTab))
        XCTAssertTrue(toc.traits.contains(.selected),
                      "the picker must highlight the segment whose content is showing")
        XCTAssertFalse(previews.traits.contains(.selected),
                       "this is the defect a patron saw: Page Previews highlighted over table-of-contents content")
    }

    // MARK: - Harness

    /// Holds the reader mode the navigation writes back through its binding, so
    /// the harness re-renders on a change exactly as the reader does.
    final class ReaderModeBox: ObservableObject {
        @Published var value: TPPPDFReaderMode = .reader
    }

    /// `TPPPDFNavigation` puts its controls in a `.toolbar`, so it needs a
    /// navigation container to render them.
    private struct Harness: View {
        @ObservedObject var mode: ReaderModeBox

        var body: some View {
            NavigationStack {
                TPPPDFNavigation(
                    readerMode: Binding(get: { mode.value }, set: { mode.value = $0 })
                ) { _ in
                    Color.clear
                }
            }
        }
    }

    private func mountNavigation() throws {
        let metadata = MockPDFDocumentMetadata()
        let mode = ReaderModeBox()
        self.metadata = metadata
        self.mode = mode
        let view = Harness(mode: mode).environmentObject(metadata as TPPPDFDocumentMetadata)
        host = AccessibilityAuditHost(UIHostingController(rootView: view))
        settle(until: { self.labelled(Strings.Generic.tableOfContents).count == 1 },
               "the toolbar's Table of Contents button must reach the accessibility tree")
    }

    /// Activate the one element carrying `label`, the way a VoiceOver double-tap
    /// does, then wait for the resulting SwiftUI update.
    ///
    /// Exactly one element must carry the label: the button and the picker's
    /// matching segment share it, and the one that is not showing is at zero
    /// opacity, which the traversal skips. Two hits would mean the assertions
    /// could be reading the control that was not tapped.
    private func activate(labelled label: String) throws {
        let window = try XCTUnwrap(host?.window)
        let matches = labelled(label)
        XCTAssertEqual(matches.count, 1, "expected one control labelled \"\(label)\", found \(matches.count)")
        let element = try XCTUnwrap(matches.first, "no control is labelled \"\(label)\"")
        let before = mode?.value
        let result = AccessibilityTraversalAudit.activate(element, in: window)
        XCTAssertTrue(result.succeeded, "could not activate \"\(label)\": \(result)")
        settle(until: { self.mode?.value != before },
               "activating \"\(label)\" must change the reader mode")
    }

    /// Pump the main runloop until `condition` holds, up to a ceiling far above
    /// what a SwiftUI update needs, so neither assertion below depends on how
    /// loaded the machine is. A fixed wait fails on a starved parallel clone.
    private func settle(until condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            host?.settle(0.05)
            if condition() { return }
        }
        XCTFail(message)
    }

    private func labelled(_ label: String) -> [AXAuditElement] {
        guard let window = host?.window else { return [] }
        return AccessibilityTraversalAudit.traverse(window).filter { $0.label == label }
    }

    /// The picker segment carrying `label`, re-read after the state change.
    ///
    /// Read only, never activated: segment selection follows the touch location,
    /// so the harness's `sendActions(for: .touchUpInside)` fallback leaves a
    /// `UISegmentedControl` on the segment it was already on.
    private func segment(labelled label: String) -> AXAuditElement? {
        guard let window = host?.window else { return nil }
        return AccessibilityTraversalAudit.traverse(window).first {
            $0.label == label && $0.path.contains("UISegment")
        }
    }
}
