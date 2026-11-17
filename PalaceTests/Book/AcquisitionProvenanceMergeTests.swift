//
//  AcquisitionProvenanceMergeTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

/// Which feed an entry came from decides what its acquisition links can do.
///
/// A loans-feed entry carries fulfillment links scoped to that loan. A catalog
/// entry for the same work carries a borrow link instead. They are not
/// interchangeable, so a merge has to say which side is authoritative rather
/// than always taking the incoming one.
///
/// `mergingPreservingMetadata(from:)` documents `fresh` as "the incoming book
/// from the loans feed (authoritative for availability and acquisitions)",
/// which is true for the sync path it was written for. The catalog-render path
/// reuses it with a catalog entry, where that precondition does not hold
/// (PP-5400): for a book on loan the catalog's link is less capable, and for an
/// LCP audiobook it erases the only signal that the book IS an LCP audiobook,
/// so the shelf offers Download instead of Listen.
final class AcquisitionProvenanceMergeTests: XCTestCase {

  // MARK: - Fixtures

  /// The acquisition an LCP audiobook carries in the loans feed: the license
  /// MIME at the top level, with the audio nested beneath it. This is the shape
  /// `LCPAudiobooks.hasLCPAcquisition` matches on.
  private var lcpLoanAcquisition: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .generic,
      type: "application/vnd.readium.lcp.license.v1.0+json",
      hrefURL: URL(string: "https://example.org/loan/fulfill/9")!,
      indirectAcquisitions: [
        TPPOPDSIndirectAcquisition(type: "application/audiobook+lcp",
                                   indirectAcquisitions: [])
      ],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }

  /// What the catalog advertises for the same work: a borrow link. Non-empty,
  /// so a "prefer non-empty" rule would not protect the loan's links from it.
  private var catalogBorrowAcquisition: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .borrow,
      type: "application/atom+xml;type=entry;profile=opds-catalog",
      hrefURL: URL(string: "https://example.org/works/ISBN/123/borrow")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }

  private func makeBook(
    identifier: String = "lcp-audiobook",
    title: String = "A Long Audiobook",
    authors: [TPPBookAuthor]? = nil,
    summary: String? = nil,
    acquisitions: [TPPOPDSAcquisition]
  ) -> TPPBook {
    TPPBook(
      acquisitions: acquisitions,
      authors: authors,
      categoryStrings: nil,
      distributor: nil,
      identifier: identifier,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: nil,
      publisher: nil,
      subtitle: nil,
      summary: summary,
      title: title,
      updated: Date(timeIntervalSince1970: 1_000_000),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      seriesName: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: nil,
      bookDuration: nil,
      imageCache: MockImageCache()
    )
  }

  private func types(of book: TPPBook) -> [String] {
    book.acquisitions.compactMap { $0.type }
  }

  // MARK: - The catalog must not replace a loan's acquisitions

  func test_metadataOnlyMerge_keepsTheLoansLCPAcquisition() {
    let onLoan = makeBook(acquisitions: [lcpLoanAcquisition])
    let fromCatalog = makeBook(acquisitions: [catalogBorrowAcquisition])

    let merged = onLoan.mergingMetadataOnly(from: fromCatalog)

    XCTAssertEqual(types(of: merged),
                   ["application/vnd.readium.lcp.license.v1.0+json"],
                   "A catalog render must not replace the loan's LCP license link")
  }

  func test_metadataOnlyMerge_leavesTheBookRecognisableAsAnLCPAudiobook() {
    // The consequence that reaches a patron: with only the catalog's atom+xml
    // link stored, the shelf cannot tell this is an LCP audiobook, so it offers
    // Download for a book that could have been played at once.
    let onLoan = makeBook(acquisitions: [lcpLoanAcquisition])
    let fromCatalog = makeBook(acquisitions: [catalogBorrowAcquisition])

    let merged = onLoan.mergingMetadataOnly(from: fromCatalog)

    XCTAssertTrue(
      merged.acquisitions.contains { $0.type == "application/vnd.readium.lcp.license.v1.0+json" },
      "The LCP license MIME is the only signal that this is a streamable LCP audiobook"
    )
  }

  // MARK: - Enrichment still has to work

  func test_metadataOnlyMerge_stillTakesRicherCatalogMetadata() {
    // The catalog path exists to fill in fields the loans feed omits. Keeping
    // acquisitions must not cost us that.
    let lean = makeBook(authors: nil, summary: nil, acquisitions: [lcpLoanAcquisition])
    let rich = makeBook(
      authors: [TPPBookAuthor(authorName: "Named Author", relatedBooksURL: nil)],
      summary: "A summary the loans feed did not send",
      acquisitions: [catalogBorrowAcquisition]
    )

    let merged = lean.mergingMetadataOnly(from: rich)

    XCTAssertEqual(merged.bookAuthors?.first?.name, "Named Author",
                   "Catalog enrichment must still flow through")
    XCTAssertEqual(merged.summary, "A summary the loans feed did not send",
                   "Catalog enrichment must still flow through")
  }

  func test_metadataOnlyMerge_doesNotLetALeanCatalogEntryWipeMetadata() {
    let rich = makeBook(
      authors: [TPPBookAuthor(authorName: "Known Author", relatedBooksURL: nil)],
      summary: "Already enriched",
      acquisitions: [lcpLoanAcquisition]
    )
    let lean = makeBook(authors: nil, summary: nil, acquisitions: [catalogBorrowAcquisition])

    let merged = rich.mergingMetadataOnly(from: lean)

    XCTAssertEqual(merged.bookAuthors?.first?.name, "Known Author")
    XCTAssertEqual(merged.summary, "Already enriched")
  }

  // MARK: - The loans path keeps adopting the feed's acquisitions

  func test_loansMerge_stillAdoptsTheFeedsAcquisitions() {
    // Guard against fixing the catalog path by breaking the sync path. The
    // loans feed IS authoritative: when a loan's links change, or a loan ends
    // and the entry is re-derived, the feed's set has to win.
    let stored = makeBook(acquisitions: [catalogBorrowAcquisition])
    let fromLoansFeed = makeBook(acquisitions: [lcpLoanAcquisition])

    let merged = stored.mergingPreservingMetadata(from: fromLoansFeed)

    XCTAssertEqual(types(of: merged),
                   ["application/vnd.readium.lcp.license.v1.0+json"],
                   "The loans feed stays authoritative for acquisitions")
  }

  func test_theTwoMergesDisagreeOnAcquisitionsAndAgreeOnMetadata() {
    // States the asymmetry in one assertion, so a future change that collapses
    // the two methods back together fails here.
    let stored = makeBook(
      authors: [TPPBookAuthor(authorName: "Stored Author", relatedBooksURL: nil)],
      acquisitions: [lcpLoanAcquisition]
    )
    let incoming = makeBook(authors: nil, acquisitions: [catalogBorrowAcquisition])

    let loans = stored.mergingPreservingMetadata(from: incoming)
    let catalog = stored.mergingMetadataOnly(from: incoming)

    XCTAssertNotEqual(types(of: loans), types(of: catalog),
                      "The two merges must differ on acquisitions")
    XCTAssertEqual(loans.bookAuthors?.first?.name, catalog.bookAuthors?.first?.name,
                   "They must agree on metadata")
  }
}
