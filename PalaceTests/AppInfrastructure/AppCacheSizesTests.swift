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
            "networkResponses": 1, "decodedImages": 2, "imageData": 3,
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

    /// Compressed cover data is kept on disk only (PP-5583); the decoded image is
    /// the one copy in memory.
    func testImageCache_KeepsCompressedDataOnDiskOnly_andCountsDecodedBytesUntilRemoved() {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "AppCacheSizes-\(UUID().uuidString)")
        let image = Self.solidImage(width: 40, height: 60)

        cache.set(image, for: "cover")
        cache.processingQueue.waitUntilAllOperationsAreFinished()

        XCTAssertGreaterThanOrEqual(cache.decodedImageBytes, 40 * 60 * 4)
        XCTAssertEqual(cache.compressedDataMemoryBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache._diskURLForTesting(for: "cover").path))

        cache.remove(for: "cover")

        XCTAssertEqual(cache.decodedImageBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache._diskURLForTesting(for: "cover").path))
        cache.clear()
    }

    /// A generated placeholder is not stored, in memory or on disk, so a cover
    /// that failed offline is fetched again once the network is back.
    func testImageCache_GeneratedPlaceholder_isNotStored() {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "AppCacheSizes-\(UUID().uuidString)")
        let placeholder = Self.solidImage(width: 40, height: 60)
        placeholder.isGeneratedCoverPlaceholder = true

        cache.set(placeholder, for: "offline")
        Self.drain(cache)

        XCTAssertNil(cache.memoryImage(for: "offline"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache._diskURLForTesting(for: "offline").path))

        cache.set(Self.solidImage(width: 40, height: 60), for: "offline")
        Self.drain(cache)

        XCTAssertNotNil(cache.memoryImage(for: "offline"), "the real cover is stored once it arrives")
        cache.clear()
    }

    /// Evicting decoded images keeps the disk copy, so the cover decodes again
    /// from disk instead of the network.
    func testImageCache_EvictDecodedImages_ZeroesDecodedBytesAndKeepsTheDiskCopy() async {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "AppCacheSizes-\(UUID().uuidString)")
        cache.set(Self.solidImage(width: 40, height: 60), for: "cover")
        Self.drain(cache)
        XCTAssertGreaterThan(cache.decodedImageBytes, 0, "precondition: the image is held decoded")

        cache.evictDecodedImages()

        XCTAssertEqual(cache.decodedImageBytes, 0)
        let fromDisk = await cache.getAsync(for: "cover")
        XCTAssertEqual(fromDisk?.cgImage?.width, 40)
        cache.clear()
    }

    /// `memoryImage(for:)` answers from memory only, so a getter can call it on
    /// the main thread.
    func testImageCache_MemoryImage_ReturnsDecodedCopyAndNotTheDiskCopy() {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "AppCacheSizes-\(UUID().uuidString)")
        cache.set(Self.solidImage(width: 40, height: 60), for: "cover")
        Self.drain(cache)
        XCTAssertNotNil(cache.memoryImage(for: "cover"))

        cache.evictDecodedImages()

        XCTAssertNil(cache.memoryImage(for: "cover"))
        cache.clear()
    }

    private static func drain(_ cache: ImageCache) {
        cache.processingQueue.waitUntilAllOperationsAreFinished()
    }

    // MARK: - LCP

    #if LCP
    /// The cache keeps each ciphertext as its key, so the key bytes are held
    /// too and count toward its size (PP-5580). The 16 MB limit still applies
    /// to the plaintext only, as before.
    func testLCPDecryptCache_CountsStoredPlaintextAndKeyBytes() {
        let cache = LCPDecryptCache()

        cache.store(Data(count: 2_048), for: Data([1, 2, 3]))
        cache.store(Data(count: 1_024), for: Data([4, 5, 6]))

        XCTAssertEqual(cache.byteCount, 3_072 + 6)
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

/// The registry keeps the fetched source bytes on disk so one cover decodes at
/// several sizes without a second request.
@MainActor
final class TPPBookCoverRegistrySourceBytesTests: XCTestCase {

    private let host = "covers.source-bytes.example"
    private var jpeg = Data()
    private var requests = RequestLog()

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL?] = []
        var count: Int { lock.withLock { urls.count } }
        func append(_ url: URL?) { lock.withLock { urls.append(url) } }
    }

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        let jpeg = try Self.coverJPEG()
        self.jpeg = jpeg
        let host = host
        let requests = RequestLog()
        self.requests = requests
        HTTPStubURLProtocol.register { request in
            guard request.url?.host == host else { return nil }
            requests.append(request.url)
            return .init(statusCode: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg)
        }
    }

    override func tearDown() async throws {
        HTTPStubURLProtocol.reset()
        try await super.tearDown()
    }

    /// Source bytes live on disk (PP-5583): a registry that has lost everything in
    /// memory decodes the cover at a new size without asking the network again.
    func testFetchedCover_SourceBytesOnDisk_newSizeAfterMemoryLossMakesNoSecondRequest() async throws {
        let sourceCache = GeneralCache<String, Data>(cacheName: "SourceBytes-\(UUID().uuidString)", mode: .diskOnly)
        let firstCache = ImageCache._makeIsolatedForTesting(cacheName: "SourceBytes-\(UUID().uuidString)")
        let first = TPPBookCoverRegistry(imageCache: firstCache, urlSession: .stubbedSession(), sourceCache: sourceCache)
        let book = makeBook()
        let cover = await first.coverImage(for: book, displayPoints: 280)
        Self.drain(firstCache)
        XCTAssertNotNil(cover, "precondition: the stubbed cover was fetched")
        XCTAssertEqual(requests.count, 1)

        let secondCache = ImageCache._makeIsolatedForTesting(cacheName: "SourceBytes-\(UUID().uuidString)")
        let second = TPPBookCoverRegistry(imageCache: secondCache, urlSession: .stubbedSession(), sourceCache: sourceCache)
        // Above `smallDisplayThreshold`, so this size asks for the same full-size URL.
        let smaller = await second.coverImage(for: book, displayPoints: 240)
        Self.drain(secondCache)

        XCTAssertNotNil(smaller)
        XCTAssertEqual(requests.count, 1, "the second size came from the disk copy")
        firstCache.clear()
        secondCache.clear()
        sourceCache.clear()
    }

    /// Source bytes last for one launch, as the in-memory cache they replace did;
    /// a launch removes the folders of earlier launches and keeps its own.
    func testRemoveEarlierLaunches_deletesOtherLaunchFoldersAndKeepsTheCurrentOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceLaunches-\(UUID().uuidString)")
        let old = root.appendingPathComponent("old-launch")
        let current = root.appendingPathComponent("this-launch")
        for folder in [old, current] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("bytes"))
        }

        TPPBookCoverRegistry.removeEarlierLaunches(in: root, keeping: "this-launch")

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("bytes").path))
        try? FileManager.default.removeItem(at: root)
    }

    /// New source bytes reaching the prune interval prune the disk cache to its
    /// limit.
    func testSourceBytesReachingThePruneInterval_pruneTheDiskCache() async throws {
        let sourceCache = GeneralCache<String, Data>(cacheName: "Prune-\(UUID().uuidString)", mode: .diskOnly)
        let registry = makePruningRegistry(sourceCache: sourceCache, interval: jpeg.count)
        let book = makeBook()

        _ = await registry.coverImage(for: book, displayPoints: 280)

        let url = try XCTUnwrap(book.imageURL)
        XCTAssertNil(sourceCache.get(for: TPPBookCoverRegistry.sourceKey(for: url)))
        sourceCache.clear()
    }

    /// Below the prune interval the source bytes stay on disk.
    func testSourceBytesUnderThePruneInterval_stayOnDisk() async throws {
        let sourceCache = GeneralCache<String, Data>(cacheName: "Prune-\(UUID().uuidString)", mode: .diskOnly)
        let registry = makePruningRegistry(sourceCache: sourceCache, interval: jpeg.count + 1)
        let book = makeBook()

        _ = await registry.coverImage(for: book, displayPoints: 280)

        let url = try XCTUnwrap(book.imageURL)
        XCTAssertEqual(sourceCache.get(for: TPPBookCoverRegistry.sourceKey(for: url)), jpeg)
        sourceCache.clear()
    }

    /// A registry whose prune empties the disk cache at once when it runs.
    private func makePruningRegistry(sourceCache: GeneralCache<String, Data>, interval: Int) -> TPPBookCoverRegistry {
        let cache = ImageCache._makeIsolatedForTesting(cacheName: "Prune-\(UUID().uuidString)")
        return TPPBookCoverRegistry(
            imageCache: cache,
            urlSession: .stubbedSession(),
            sourceCache: sourceCache,
            sourcePrunePolicy: .init(byteLimit: 0, interval: interval, schedule: { $0() })
        )
    }

    /// The source-byte caches keep nothing in memory (PP-5583).
    func testSourceCaches_holdNoBytesInMemory() throws {
        let instance = TPPBookCoverRegistry.makeInstanceSourceCache()
        let url = try XCTUnwrap(URL(string: "https://\(host)/memory-check-\(UUID().uuidString)"))
        let key = TPPBookCoverRegistry.sourceKey(for: url)

        instance.set(Data(count: 2_000), for: key, expiresIn: 60)
        TPPBookCoverRegistry.launchSourceCache.set(Data(count: 2_000), for: key, expiresIn: 60)

        XCTAssertEqual(instance.memoryBytes, 0)
        XCTAssertEqual(TPPBookCoverRegistry.launchSourceCache.memoryBytes, 0)
        instance.clear()
        TPPBookCoverRegistry.launchSourceCache.remove(for: key)
    }

    /// URLs that differ only in punctuation get separate files: the cache strips
    /// punctuation from raw keys, so the key is a hash.
    func testSourceKey_punctuationOnlyURLs_getDistinctFiles() throws {
        let cache = TPPBookCoverRegistry.makeInstanceSourceCache()
        let a = TPPBookCoverRegistry.sourceKey(for: try XCTUnwrap(URL(string: "https://\(host)/a.b")))
        let b = TPPBookCoverRegistry.sourceKey(for: try XCTUnwrap(URL(string: "https://\(host)/ab")))

        XCTAssertNotEqual(cache.fileURL(for: a), cache.fileURL(for: b))
    }

    /// A URL longer than a file name allows still round-trips through the cache.
    func testSourceKey_urlOver255Characters_roundTrips() throws {
        let cache = TPPBookCoverRegistry.makeInstanceSourceCache()
        let long = try XCTUnwrap(URL(string: "https://\(host)/" + String(repeating: "c", count: 400)))
        let key = TPPBookCoverRegistry.sourceKey(for: long)

        cache.set(jpeg, for: key, expiresIn: 60)

        XCTAssertEqual(cache.get(for: key), jpeg)
        cache.clear()
    }

    /// The app's image loader and the shared registry use one launch cache, so a
    /// cover fetched for the player is not fetched again for a list.
    func testProductionImageLoader_sharesTheLaunchSourceCache() throws {
        let loader = try XCTUnwrap(AppContainer.production().imageLoader as? ImageLoader)
        XCTAssertIdentical(loader.sourceCache, TPPBookCoverRegistry.launchSourceCache)
    }

    /// The source-byte disk cache is bounded: over the limit the oldest files go.
    func testGeneralCachePrune_deletesOldestFilesUntilUnderTheLimit() {
        let cache = GeneralCache<String, Data>(cacheName: "Prune-\(UUID().uuidString)", mode: .diskOnly)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for (offset, name) in ["first", "second", "third"].enumerated() {
            cache.set(Data(count: 1_000), for: name, expiresIn: 60)
            // Set the order here; file system timestamps can tie.
            try? FileManager.default.setAttributes(
                [.creationDate: base.addingTimeInterval(TimeInterval(offset))],
                ofItemAtPath: cache.fileURL(for: name).path
            )
        }

        cache.prune(maxBytes: 2_000)

        XCTAssertNil(cache.get(for: "first"))
        XCTAssertNotNil(cache.get(for: "second"))
        XCTAssertNotNil(cache.get(for: "third"))
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
