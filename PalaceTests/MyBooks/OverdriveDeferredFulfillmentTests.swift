//
//  OverdriveDeferredFulfillmentTests.swift
//  PalaceTests
//
//  Regression: Overdrive borrow-from-hold failing with "wrong headers" Code=609.
//
//  When a held Overdrive audiobook is borrowed, `borrowAsync` succeeds and sets
//  state to `.downloadNeeded`, then auto-triggers `startDownload`. The
//  post-borrow OPDS entry returned by the Palace Circulation Manager still
//  advertises the `/borrow` URL as the default acquisition, so
//  `processOverdriveDownload` calls `fulfillBook` with that URL.
//  `OverdriveAPIExecutor.fulfillBook` expects a 302 with
//  `x-overdrive-scope` and `x-overdrive-patron-authorization` headers; the CM
//  returns a 200 OPDS atom entry instead, and the client logs
//  `Overdrive audiobook fulfillment: wrong headers` (Code 609).
//
//  `MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for:state:)` is the
//  guard that prevents that spurious call. This file covers the guard's truth
//  table: only borrow-relation acquisitions in download-ready states defer.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class OverdriveDeferredFulfillmentTests: XCTestCase {

    // MARK: - Helpers

    private func makeBook(relation: TPPOPDSAcquisitionRelation) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: relation,
            type: "application/vnd.overdrive.circulation.api+json;profile=audiobook",
            hrefURL: URL(string: "https://example.com/works/Overdrive%20ID/abc/borrow")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )

        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: "Overdrive",
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Held Overdrive Audiobook",
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    // MARK: - Guard fires (must defer)

    func testDeferFires_whenDownloadNeededWithBorrowAcquisition() {
        let book = makeBook(relation: .borrow)

        XCTAssertTrue(
            MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for: book, state: .downloadNeeded),
            "A .downloadNeeded book whose default acquisition is still `.borrow` must defer — calling fulfillBook with a /borrow URL produces a 'wrong headers' error."
        )
    }

    func testDeferFires_whenDownloadFailedWithBorrowAcquisition() {
        // Retry after a failed auto-fulfillment hits the same path; guard must still fire.
        let book = makeBook(relation: .borrow)

        XCTAssertTrue(
            MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for: book, state: .downloadFailed),
            "Retrying a .downloadFailed book with a borrow acquisition must also defer."
        )
    }

    // MARK: - Guard does NOT fire (must proceed to fulfillment)

    func testDeferSkipped_whenDefaultAcquisitionIsGeneric() {
        let book = makeBook(relation: .generic)

        XCTAssertFalse(
            MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for: book, state: .downloadNeeded),
            "A .generic (fulfill) acquisition is the normal Overdrive fulfillment URL — guard must not fire."
        )
    }

    func testDeferSkipped_whenDefaultAcquisitionIsOpenAccess() {
        let book = makeBook(relation: .openAccess)

        XCTAssertFalse(
            MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for: book, state: .downloadNeeded),
            "Open-access acquisitions are downloadable directly — guard must not fire."
        )
    }

    func testDeferSkipped_whenStateIsUnregistered() {
        // Unregistered routes to startBorrow regardless of acquisition type — guard is upstream of that.
        let book = makeBook(relation: .borrow)

        XCTAssertFalse(
            MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for: book, state: .unregistered),
            "State .unregistered is handled by the borrow path, not the fulfillment path."
        )
    }

    func testDeferSkipped_whenStateIsHolding() {
        // Holding also routes to startBorrow — guard doesn't need to fire.
        let book = makeBook(relation: .borrow)

        XCTAssertFalse(
            MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for: book, state: .holding),
            "State .holding is handled by the borrow path, not the fulfillment path."
        )
    }
}
