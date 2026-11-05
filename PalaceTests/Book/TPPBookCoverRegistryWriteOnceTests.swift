//  TPPBookCoverRegistryWriteOnceTests.swift
//
//  A cover fetched once is encoded once, though the registry stores it under
//  both its sized key and the bare identifier (PP-5499).

import XCTest
import UIKit
@testable import Palace
@testable import PalaceBookModel

@MainActor
final class TPPBookCoverRegistryWriteOnceTests: XCTestCase {

    private var cache: ImageCache!
    private var registry: TPPBookCoverRegistry!
    private var encodeCount: LockIsolated<Int>!

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        let jpeg = try Self.coverJPEG()
        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "covers.write-once.example" else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg)
        }
        let counter = LockIsolated(0)
        encodeCount = counter
        cache = ImageCache._makeIsolatedForTesting(
            cacheName: "CoverRegistryWriteOnce-\(UUID().uuidString)",
            encode: { image, quality in
                counter.withValue { $0 += 1 }
                return image.jpegData(compressionQuality: quality)
            }
        )
        registry = TPPBookCoverRegistry(imageCache: cache, urlSession: .stubbedSession())
    }

    override func tearDown() async throws {
        HTTPStubURLProtocol.reset()
        Self.drain(cache)
        cache.clear()
        registry = nil
        cache = nil
        try await super.tearDown()
    }

    func testSizedCover_fetchedOnce_isEncodedOnceForBothKeys() async throws {
        let book = makeBook()

        let cover = await registry.coverImage(for: book, displayPoints: 280)
        Self.drain(cache)

        XCTAssertNotNil(cover)
        XCTAssertEqual(encodeCount.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache._diskURLForTesting(for: book.identifier).path),
                      "the bare identifier must still be stored")
    }

    private static func coverJPEG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    private func makeBook() -> TPPBook {
        let id = "write-once-\(UUID().uuidString)"
        return TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: id,
            imageURL: URL(string: "https://covers.write-once.example/full/\(id).jpg"),
            imageThumbnailURL: URL(string: "https://covers.write-once.example/thumb/\(id).jpg"),
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Write Once",
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

    /// Synchronous so async tests can call it: `waitUntilAllOperationsAreFinished`
    /// is unavailable from async contexts.
    private static func drain(_ cache: ImageCache) {
        cache.processingQueue.waitUntilAllOperationsAreFinished()
    }

}
