//
//  AppCacheSizesTests.swift
//  PalaceTests
//
//  PP-5509: each cache the app owns reports its bytes to the memory event
//  line. These tests pin that every cache feeds its count, and that the
//  launch registration puts every field on the line.
//

import XCTest
import PDFKit
import UIKit
@testable import Palace
@testable import PalaceBookModel
import PalaceCatalog

final class AppCacheSizesTests: XCTestCase {

    private let megabyte = 1024 * 1024

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    // MARK: - Registration

    /// Each field must show its own cache's size; a swapped pair of sources
    /// would put plausible numbers under the wrong names.
    func testRegister_EachFieldShowsItsOwnSourcesSize() throws {
        let lines = Lines()
        let recorder = MemoryEventRecorder(footprint: { 0 }, available: { 0 }, write: { lines.append($0) })
        let mb = megabyte
        var sources = AppCacheSizes.Sources(
            networkResponses: { 1 * mb },
            decodedImages: { 2 * mb },
            imageData: { 3 * mb },
            coverSourceData: { 4 * mb },
            bookCovers: { 5 * mb },
            opdsFeedData: { 6 * mb },
            pdfPreviews: { 7 * mb },
            pdfThumbnails: { 8 * mb }
        )
        sources.lcpDecrypt = { 9 * mb }

        AppCacheSizes.register(on: recorder, sources: sources)
        recorder.record(.warning)

        let line = try XCTUnwrap(lines.all.first)
        var expected = [
            "networkResponses": 1, "decodedImages": 2, "imageData": 3, "coverSourceData": 4,
            "bookCovers": 5, "opdsFeedData": 6, "pdfPreviews": 7, "pdfThumbnails": 8
        ]
        #if LCP
        expected["lcpDecrypt"] = 9
        #endif
        for (name, value) in expected {
            XCTAssertTrue(line.contains("cache.\(name)MB=\(value) ") || line.hasSuffix("cache.\(name)MB=\(value)"),
                          "\(name) should be \(value) in \(line)")
        }
    }

    // MARK: - GeneralCache

    func testGeneralCache_MemoryBytesFollowSetAndRemove() {
        let cache = GeneralCache<String, Data>(cacheName: "AppCacheSizes-\(UUID().uuidString)", mode: .memoryOnly)

        cache.set(Data(count: 1_000), for: "a")
        cache.set(Data(count: 500), for: "b")
        XCTAssertEqual(cache.memoryBytes, 1_500)

        cache.remove(for: "a")
        XCTAssertEqual(cache.memoryBytes, 500)

        cache.clearMemory()
        XCTAssertEqual(cache.memoryBytes, 0)
    }

    // MARK: - ImageCache

    func testImageCache_CountsDecodedAndCompressedBytesUntilRemoved() {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "AppCacheSizes-\(UUID().uuidString)")
        let image = Self.solidImage(width: 40, height: 60)

        cache.set(image, for: "cover")
        cache.processingQueue.waitUntilAllOperationsAreFinished()

        XCTAssertGreaterThanOrEqual(cache.decodedImageBytes, 40 * 60 * 4)
        XCTAssertGreaterThan(cache.compressedDataMemoryBytes, 0)

        cache.remove(for: "cover")

        XCTAssertEqual(cache.decodedImageBytes, 0)
        XCTAssertEqual(cache.compressedDataMemoryBytes, 0)
        cache.clear()
    }

    func testImageCache_EvictDecodedImages_ZeroesDecodedBytesOnly() {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "AppCacheSizes-\(UUID().uuidString)")
        cache.set(Self.solidImage(width: 40, height: 60), for: "cover")
        cache.processingQueue.waitUntilAllOperationsAreFinished()
        let compressed = cache.compressedDataMemoryBytes
        XCTAssertGreaterThan(cache.decodedImageBytes, 0, "precondition: the image is held decoded")

        cache.evictDecodedImages()

        XCTAssertEqual(cache.decodedImageBytes, 0)
        XCTAssertEqual(cache.compressedDataMemoryBytes, compressed)
        cache.clear()
    }

    // MARK: - LCP

    #if LCP
    func testLCPDecryptCache_CountsStoredPlaintextBytes() {
        let cache = LCPDecryptCache()

        cache.store(Data(count: 2_048), for: Data([1, 2, 3]))
        cache.store(Data(count: 1_024), for: Data([4, 5, 6]))

        XCTAssertEqual(cache.byteCount, 3_072)
        XCTAssertEqual(cache.decrypted(for: Data([1, 2, 3]))?.count, 2_048)
    }
    #endif

    // MARK: - OPDS feed data

    func testOPDSFeedCache_CountsStoredFeedDataUntilRemoved() async throws {
        let counter = CacheByteCounter()
        let cache = OPDS2FeedCache(
            configuration: .init(staleTTL: 60, maxAge: 600, maxMemoryEntries: 10, persistToDisk: true),
            diskCacheName: "AppCacheSizes-\(UUID().uuidString)",
            dataByteCounter: counter
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/feed"))
        let entry = OPDSCacheEntry(feed: OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Counted"),
            links: [OPDS2Link(href: "https://example.com", rel: "self")]
        ))
        let encoded = try JSONEncoder().encode(entry)

        await cache.set(entry, for: url)
        XCTAssertEqual(counter.bytes, encoded.count)
        XCTAssertEqual(cache.dataMemoryBytes, encoded.count)

        await cache.remove(for: url)
        XCTAssertEqual(counter.bytes, 0)
        await cache.clear()
    }

    // MARK: - PDF thumbnails

    func testPDFThumbnailProvider_CountsRenderedThumbnailsAndReleasesThemOnDeinit() throws {
        let counter = CacheByteCounter()
        var provider: PDFKitThumbnailProvider? = PDFKitThumbnailProvider(
            document: try Self.makePDF(pageCount: 2),
            byteCounter: counter
        )

        let image = try XCTUnwrap(provider?.thumbnail(for: 0))
        XCTAssertEqual(counter.bytes, image.decodedByteCount)
        XCTAssertGreaterThan(counter.bytes, 0)

        provider = nil

        XCTAssertEqual(counter.bytes, 0)
    }

    // MARK: - BookCoverStore

    func testBookCoverStore_CountsEachStoredImageOnce() {
        let store = BookCoverStore(colorQueue: DispatchQueue(label: "AppCacheSizesTests.color"), colorExtractor: { _ in .red })
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        store.register(book, for: "id-a")
        let cover = Self.solidImage(width: 30, height: 30)
        let thumbnail = Self.solidImage(width: 10, height: 10)

        store.update("id-a") {
            $0.coverImage = cover
            $0.thumbnailImage = thumbnail
            $0.colorSource = cover
        }

        XCTAssertEqual(store.imageByteCount, cover.decodedByteCount + thumbnail.decodedByteCount)

        store.unregister(ObjectIdentifier(book), for: "id-a")

        XCTAssertEqual(store.imageByteCount, 0)
        withExtendedLifetime(book) {}
    }

    // MARK: - Helpers

    static func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func makePDFData(pageCount: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for _ in 0..<pageCount {
                ctx.beginPage()
                UIColor.white.setFill()
                ctx.fill(bounds)
            }
        }
    }

    static func makePDF(pageCount: Int) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: makePDFData(pageCount: pageCount)))
    }
}

/// The registry keeps the fetched source bytes so one cover decodes at several
/// sizes without a second request; those bytes are on the memory event line.
@MainActor
final class TPPBookCoverRegistrySourceBytesTests: XCTestCase {

    private let host = "covers.source-bytes.example"
    private var jpeg = Data()

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        let jpeg = try Self.coverJPEG()
        self.jpeg = jpeg
        let host = host
        HTTPStubURLProtocol.register { request in
            guard request.url?.host == host else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg)
        }
    }

    override func tearDown() async throws {
        HTTPStubURLProtocol.reset()
        try await super.tearDown()
    }

    func testFetchedCover_CountsItsSourceBytes() async throws {
        let counter = CacheByteCounter()
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "SourceBytes-\(UUID().uuidString)")
        let registry = TPPBookCoverRegistry(imageCache: cache, urlSession: .stubbedSession(), sourceDataCounter: counter)
        let book = makeBook()

        let cover = await registry.coverImage(for: book, displayPoints: 280)
        Self.drain(cache)

        XCTAssertNotNil(cover, "precondition: the stubbed cover was fetched")
        XCTAssertEqual(counter.bytes, jpeg.count)
        XCTAssertEqual(registry.sourceDataBytes, counter.bytes)
        cache.clear()
    }

    private func makeBook() -> TPPBook {
        let id = "source-bytes-\(UUID().uuidString)"
        return TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: id,
            imageURL: URL(string: "https://\(host)/full/\(id).jpg"),
            imageThumbnailURL: URL(string: "https://\(host)/thumb/\(id).jpg"),
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Source Bytes",
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

    private static func coverJPEG() throws -> Data {
        try XCTUnwrap(AppCacheSizesTests.solidImage(width: 40, height: 60).jpegData(compressionQuality: 0.8))
    }
}

/// The preview grid is made per screen, so all grids report into one counter.
@MainActor
final class TPPPDFPreviewGridCacheSizeTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() async throws {
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    func testPreviewGrid_MemoryWarning_ZeroesCountedPreviews() async throws {
        let counter = CacheByteCounter()
        let grid = show(TPPPDFPreviewGridController(document: Self.document(), indices: nil, byteCounter: counter))
        await awaitConditionAsync(timeout: 5) { counter.bytes > 0 }
        XCTAssertGreaterThan(counter.bytes, 0, "a rendered preview is counted")

        grid.didReceiveMemoryWarning()

        XCTAssertEqual(counter.bytes, 0)
    }

    func testPreviewGrid_Released_RemovesItsBytesFromTheSharedCounter() async throws {
        let counter = CacheByteCounter()
        weak var released: TPPPDFPreviewGridController?
        do {
            let grid = show(TPPPDFPreviewGridController(document: Self.document(), indices: nil, byteCounter: counter))
            released = grid
            await awaitConditionAsync(timeout: 5) { counter.bytes > 0 }
            XCTAssertGreaterThan(counter.bytes, 0, "a rendered preview is counted")
        }

        window?.rootViewController = nil
        await awaitConditionAsync(timeout: 5) { released == nil }

        XCTAssertEqual(counter.bytes, 0)
    }

    private func show(_ grid: TPPPDFPreviewGridController) -> TPPPDFPreviewGridController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = grid
        window.isHidden = false
        grid.collectionView.layoutIfNeeded()
        self.window = window
        return grid
    }

    private static func document() -> TPPPDFDocument {
        TPPPDFDocument(data: AppCacheSizesTests.makePDFData(pageCount: 2))
    }
}
