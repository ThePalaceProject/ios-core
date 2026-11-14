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
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)

        ReadiumPDFLoadingView.requestCoverIfMissing(for: book)
        await awaitConditionAsync(timeout: 3) { loader.coverCalls.contains { $0.displayPoints == 200 } }

        XCTAssertTrue(loader.coverCalls.contains { $0.identifier == book.identifier && $0.displayPoints == 200 })
    }

    func testRequestCoverIfMissing_withCover_asksForNothing() async {
        let loader = MockImageLoader()
        TPPBookImageContext.imageLoaderProvider = { loader }
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        book.coverImage = cover
        await drainMainQueueAsync()
        let before = loader.coverCalls.count

        ReadiumPDFLoadingView.requestCoverIfMissing(for: book)
        await drainMainQueueAsync()

        XCTAssertEqual(loader.coverCalls.count, before)
        withExtendedLifetime(cover) {}
    }
}
