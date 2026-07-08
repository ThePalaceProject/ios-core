//
//  ImageCoverKeyUnificationTests.swift
//  PalaceTests
//
//  Pins the B2 cover/prefetch source-URL unification. `sourceData(for:)` in
//  `TPPBookCoverRegistry` dedups by absolute URL, and prefetch always fetches
//  `imageThumbnailURL`. So for a small (catalog-cell) display the cell's cover
//  fetch must resolve to that SAME thumbnail URL — otherwise the cell pulls the
//  full-res `imageURL` a second time and the two never coalesce. Larger displays
//  must keep the full-resolution URL, proving the size branch actually
//  discriminates rather than always returning one side.
//

import XCTest
@testable import Palace

final class ImageCoverKeyUnificationTests: XCTestCase {

    func testCoverKey_cellAndPrefetch_coalesceForSmallDisplay() throws {
        let fullSizeURL = try XCTUnwrap(URL(string: "https://covers.example.org/full/book-1.jpg"))
        let thumbnailURL = try XCTUnwrap(URL(string: "https://covers.example.org/thumb/book-1.jpg"))

        // Prefetch (CatalogViewModel.prefetchThumbnails → thumbnailImage) always
        // fetches the thumbnail URL; sourceData(for:) keys the download by URL.
        let prefetchSourceURL = thumbnailURL

        // A ~150pt catalog cell is a "small" display.
        let cellSourceURL = TPPBookCoverRegistry.coverSourceURL(
            imageURL: fullSizeURL,
            thumbnailURL: thumbnailURL,
            displayPoints: 150
        )
        XCTAssertEqual(
            cellSourceURL,
            prefetchSourceURL,
            "Small-display cover fetch must resolve to the same URL prefetch uses so the source-bytes download coalesces"
        )

        // Contrast case: a full-screen player/detail display keeps the
        // full-resolution URL, proving the size branch discriminates.
        let largeSourceURL = TPPBookCoverRegistry.coverSourceURL(
            imageURL: fullSizeURL,
            thumbnailURL: thumbnailURL,
            displayPoints: 600
        )
        XCTAssertEqual(
            largeSourceURL,
            fullSizeURL,
            "Large-display cover fetch must keep the full-resolution imageURL"
        )
    }

    func testCoverSourceURL_smallDisplayWithNoThumbnail_fallsBackToFullSize() throws {
        let fullSizeURL = try XCTUnwrap(URL(string: "https://covers.example.org/full/book-2.jpg"))

        // No thumbnail available — even a small display must fall back to the
        // full-size URL rather than returning nil.
        let resolved = TPPBookCoverRegistry.coverSourceURL(
            imageURL: fullSizeURL,
            thumbnailURL: nil,
            displayPoints: 150
        )
        XCTAssertEqual(
            resolved,
            fullSizeURL,
            "A small display with no thumbnail must fall back to the full-size imageURL"
        )
    }
}
