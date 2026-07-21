//
//  ReaderEditingActionsTests.swift
//  PalaceTests
//
//  PP-4297: Pin the EPUB/PDF reader gating logic that decides whether the
//  system text-selection edit menu (Copy, Cut, Paste, Look Up, Share, …)
//  is exposed for the book currently being read.
//

import XCTest
import PalaceCatalog
import ReadiumNavigator
@testable import Palace

@MainActor
final class ReaderEditingActionsTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    private static let testURL = URL(string: "https://test.example.com/borrow")!

    // MARK: - Test fixtures

    private func makeBook(identifier: String, acquisitions: [TPPOPDSAcquisition]) -> TPPBook {
        TPPBook(
            acquisitions: acquisitions,
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: ImageCache.shared
        )
    }

    private func lcpEpubBook() -> TPPBook {
        let epubLeaf = TPPOPDSIndirectAcquisition(type: ContentTypeEpubZip, indirectAcquisitions: [])
        let lcpLicense = TPPOPDSIndirectAcquisition(type: ContentTypeReadiumLCP, indirectAcquisitions: [epubLeaf])
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSCatalog,
            hrefURL: Self.testURL,
            indirectAcquisitions: [lcpLicense],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return makeBook(identifier: "lcp-epub", acquisitions: [acquisition])
    }

    private func openAccessEpubBook() -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .openAccess,
            type: ContentTypeEpubZip,
            hrefURL: Self.testURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return makeBook(identifier: "open-epub", acquisitions: [acquisition])
    }

    private static var highlight: EditingAction { EditingAction(title: "Highlight", action: Selector("highlight")) }

    // MARK: - Gating

    func testResolve_returnsEmpty_forDRMBook() {
        let actions = ReaderEditingActions.resolve(for: lcpEpubBook())
        XCTAssertTrue(actions.isEmpty,
                      "DRM-protected book must collapse the editing-actions list to [] so no system edit menu appears on long-press.")
    }

    func testResolve_returnsEmpty_forDRMBook_evenWithCustomActions() {
        // The Highlight custom action is a Palace-side feature; it must NOT
        // leak the edit menu open on DRM titles. Any non-empty action list
        // would surface the menu on long-press selection.
        let actions = ReaderEditingActions.resolve(for: lcpEpubBook(), appending: [Self.highlight])
        XCTAssertTrue(actions.isEmpty,
                      "DRM-protected book must suppress ALL editing actions — including caller-supplied custom ones like Highlight.")
    }

    func testResolve_returnsDefaultActions_forNonDRMBook() {
        let actions = ReaderEditingActions.resolve(for: openAccessEpubBook())
        XCTAssertEqual(actions, EditingAction.defaultActions,
                       "Non-DRM book must surface Readium's default editing actions (copy, share, lookup, translate).")
    }

    func testResolve_appendsCustomActions_forNonDRMBook() {
        // Bind a SINGLE highlight instance: `Self.highlight` is a computed property
        // that mints a fresh `EditingAction` (wrapping a new `UIMenuItem`) on every
        // read, and `EditingAction`/`UIMenuItem` compare by pointer identity — so
        // reading it twice (once as input, once as expected) would spuriously fail.
        let highlight = Self.highlight
        let actions = ReaderEditingActions.resolve(for: openAccessEpubBook(), appending: [highlight])
        XCTAssertEqual(actions, EditingAction.defaultActions + [highlight],
                       "Non-DRM book must surface defaults PLUS caller-supplied custom actions (Highlight).")
    }

    func testResolve_treatsSampleOfDRMBook_asNonDRM() {
        // Samples are open-access preview content even when the parent book
        // is DRM-protected — borrow flow is gated, not preview reading.
        // Single highlight instance — see sibling test (pointer-identity equality).
        let highlight = Self.highlight
        let actions = ReaderEditingActions.resolve(for: lcpEpubBook(), isSample: true, appending: [highlight])
        XCTAssertEqual(actions, EditingAction.defaultActions + [highlight],
                       "Sample preview of a DRM book must still surface the full edit menu — samples are open-access content.")
    }
}
