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

final class AppCacheSizesTests: XCTestCase {

    private let megabyte = 1024 * 1024

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    // MARK: - Registration

    func testRegister_PutsEveryAppCacheOnTheMemoryEventLine() throws {
        let lines = Lines()
        let recorder = MemoryEventRecorder(footprint: { 0 }, available: { 0 }, write: { lines.append($0) })
        let mb = megabyte

        AppCacheSizes.register(on: recorder, networkResponses: { 3 * mb })
        recorder.record(.warning)

        let line = try XCTUnwrap(lines.all.first)
        XCTAssertTrue(line.contains("cache.networkResponsesMB=3"), line)
        var expected = ["decodedImages", "imageData", "coverSourceData", "bookCovers",
                        "opdsFeedData", "pdfPreviews", "pdfThumbnails"]
        #if LCP
        expected.append("lcpDecrypt")
        #endif
        for name in expected {
            XCTAssertTrue(line.contains("cache.\(name)MB="), "missing \(name) in \(line)")
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
