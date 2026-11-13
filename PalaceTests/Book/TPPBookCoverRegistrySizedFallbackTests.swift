//  TPPBookCoverRegistrySizedFallbackTests.swift
//
//  When a sized cover cannot be fetched (offline, host down, bad response), a
//  real cover already cached under the bare identifier beats a TenPrint.

import XCTest
import UIKit
@testable import Palace
@testable import PalaceBookModel

@MainActor
final class TPPBookCoverRegistrySizedFallbackTests: XCTestCase {

    private var cache: MockImageCache!
    private var registry: TPPBookCoverRegistry!

    override func setUp() async throws {
        try await super.setUp()
        // No handler is registered, so every cover URL answers 501.
        HTTPStubURLProtocol.reset()
        cache = MockImageCache()
        registry = TPPBookCoverRegistry(imageCache: cache, urlSession: .stubbedSession())
    }

    override func tearDown() async throws {
        HTTPStubURLProtocol.reset()
        registry = nil
        cache = nil
        try await super.tearDown()
    }

    func testSizedCover_whenFetchFailsAndBareCoverIsCached_returnsTheCachedCover() async {
        let book = makeBook()
        let cached = UIImage()
        cache.set(cached, for: book.identifier, expiresIn: nil)

        let result = await registry.coverImage(for: book, displayPoints: 280)

        XCTAssertIdentical(result, cached)
    }

    func testSizedCover_whenFetchFailsAndNothingIsCached_stillReturnsAPlaceholder() async {
        let book = makeBook()

        let result = await registry.coverImage(for: book, displayPoints: 280)

        XCTAssertNotNil(result, "with no cached cover the TenPrint placeholder is still shown")
    }

    /// The detail view treats heights above this as large; the registry serves thumbnails at or below it.
    func testLargeCoverThreshold_matchesRegistryThumbnailThreshold() {
        XCTAssertEqual(TPPBook.largeCoverMinimumDisplayHeight, TPPBookCoverRegistry.smallDisplayThreshold)
    }

    private func makeBook() -> TPPBook {
        let id = "sized-fallback-\(UUID().uuidString)"
        return TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: id,
            imageURL: URL(string: "https://covers.sized-fallback.example/full/\(id).jpg"),
            imageThumbnailURL: URL(string: "https://covers.sized-fallback.example/thumb/\(id).jpg"),
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Sized Fallback",
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
}
