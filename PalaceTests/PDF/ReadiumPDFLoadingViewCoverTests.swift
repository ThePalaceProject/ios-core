//
//  ReadiumPDFLoadingViewCoverTests.swift
//  PalaceTests
//
//  The PDF loading screen asks for a missing cover through the book's cover
//  path, which reads the disk caches first (PP-5583).
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class ReadiumPDFLoadingViewCoverTests: XCTestCase {

    override func tearDown() {
        TPPBookImageContext._resetForTesting()
        super.tearDown()
    }

    func testRequestCoverIfMissing_withoutCover_asksTheLoaderAtTheThumbnailSize() async {
        let loader = MockImageLoader()
        TPPBookImageContext.imageLoaderProvider = { loader }
        let book = Self.makeBookWithoutCover()
        await drainMainQueueAsync()
        XCTAssertNil(book.coverImage, "precondition: no cover in memory")

        ReadiumPDFLoadingView.requestCoverIfMissing(for: book)
        await awaitConditionAsync(timeout: 3) { loader.coverCalls.contains { $0.displayPoints == 200 } }

        XCTAssertTrue(loader.coverCalls.contains { $0.identifier == book.identifier && $0.displayPoints == 200 })
    }

    func testRequestCoverIfMissing_withCover_asksForNothing() async {
        let loader = MockImageLoader()
        TPPBookImageContext.imageLoaderProvider = { loader }
        let book = Self.makeBookWithoutCover()
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        book.coverImage = cover
        await drainMainQueueAsync()
        let before = loader.coverCalls.count

        ReadiumPDFLoadingView.requestCoverIfMissing(for: book)
        await drainMainQueueAsync()

        XCTAssertEqual(loader.coverCalls.count, before)
        withExtendedLifetime(cover) {}
    }

    /// A book with a cover URL and no cover in memory: the image context's loader
    /// answers nothing while the book is built.
    private static func makeBookWithoutCover() -> TPPBook {
        let id = "no-cover-\(UUID().uuidString)"
        return TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: id,
            imageURL: URL(string: "https://covers.example/\(id).jpg"),
            imageThumbnailURL: nil,
            published: nil,
            publisher: "",
            subtitle: "",
            summary: "",
            title: "No Cover",
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
