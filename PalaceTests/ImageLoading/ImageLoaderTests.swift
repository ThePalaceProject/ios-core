import XCTest
import UIKit
import PalaceCatalog
@testable import Palace

/// Unit tests for the new `ImageLoader` umbrella that replaces the
/// `TPPBookCoverRegistry` + `TPPBookCoverRegistryBridge` + `ImageCache.shared`
/// trio at call sites. Covers cache-hit short-circuits, weak-book-reference
/// safety on the completion bridge, and the placeholder fall-through.
@MainActor
final class ImageLoaderTests: XCTestCase {

    private var cache: MockImageCache!
    private var loader: ImageLoader!

    override func setUp() {
        super.setUp()
        cache = MockImageCache()
        loader = ImageLoader(imageCache: cache)
    }

    override func tearDown() {
        loader = nil
        cache = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBook(
        identifier: String = UUID().uuidString,
        title: String = "Title",
        author: String = "Author",
        imageURL: URL? = nil,
        thumbnailURL: URL? = nil
    ) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "https://example.com/\(identifier)")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: author, relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: imageURL,
            imageThumbnailURL: thumbnailURL,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: title,
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
            contributors: nil,
            bookDuration: nil,
            imageCache: cache
        )
    }

    private func makeImage(width: CGFloat = 4, height: CGFloat = 4, color: UIColor = .red) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 1)
        defer { UIGraphicsEndImageContext() }
        color.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
        return UIGraphicsGetImageFromCurrentImageContext()!
    }

    // MARK: - Cache routing

    func testCoverImage_cacheHit_returnsCachedImageWithoutTouchingFallback() async {
        // Arrange: preload the cache under the cover key the loader looks up.
        let book = makeBook(imageURL: URL(string: "https://example.com/img.jpg")!)
        let cached = makeImage(color: .green)
        cache.set(cached, for: "\(book.identifier)_cover", expiresIn: nil)
        // Drop the setup's set() from setKeys so the post-act assertion
        // measures only what the LOADER wrote, not what the test pre-populated.
        cache.resetHistory()

        // Act
        let result = await loader.coverImage(for: book)

        // Assert: returned the cached image and never wrote a NEW entry under
        // the cover key (proves it didn't fetch + decode + restore).
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pngData(), cached.pngData())
        XCTAssertFalse(cache.setKeys.contains("\(book.identifier)_cover"),
                       "cache.set should not be called when the cover key is already populated")
    }

    func testCoverImage_displayPoints_cacheHit_skipsNetwork() async {
        // The displayPoints variant keys on identifier_<px>px — preload that
        // and assert the loader short-circuits before checking imageURL.
        let book = makeBook(imageURL: URL(string: "https://example.com/img.jpg")!)
        let scale = await MainActor.run { UIScreen.main.scale }
        let neededPixels = min(100 * scale * 1.5, 1200)
        let key = "\(book.identifier)_\(Int(neededPixels))px"
        let preloaded = makeImage(color: .blue)
        cache.set(preloaded, for: key, expiresIn: nil)
        // Drop the setup's set() from setKeys — see sibling test above.
        cache.resetHistory()

        let result = await loader.coverImage(for: book, displayPoints: 100)

        XCTAssertEqual(result?.pngData(), preloaded.pngData())
        XCTAssertFalse(cache.setKeys.contains(key),
                       "cache.set should not be called when the displayPoints key is already populated")
    }

    // MARK: - Placeholder fallthrough

    func testThumbnailImage_falsBackToTenPrintPlaceholder_whenThumbnailURLIsNil() async {
        // Both URLs nil -> registry has nothing to fetch; loader must render
        // a TenPrint placeholder rather than returning nil.
        let book = makeBook(imageURL: nil, thumbnailURL: nil)

        let result = await loader.thumbnailImage(for: book)

        XCTAssertNotNil(result, "thumbnailImage must return a TenPrint placeholder when no URL is available")
    }

    // MARK: - Completion bridge

    // Swift 6: a captured `var` mutated inside the completion (which fires on a
    // different executor than the one that declared it) is a data race. Box it
    // behind a lock — the write in the completion and the read after `wait`
    // synchronize through the lock. Mirrors the @unchecked Sendable box idiom
    // used across the test suite (e.g. AudiobookPlaytimesLifecycleTests.AccountIdBox).
    private final class MainThreadFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    func testCompletionBridge_thumbnail_invokesOnMainThread() {
        let book = makeBook()
        let expectation = expectation(description: "thumbnail completion fires")
        let ranOnMain = MainThreadFlag()

        // Drive the call from a background queue to force the implementation
        // to hop back to main for completion (the contract the old bridge
        // guaranteed and the new ImageLoading must preserve).
        // Swift 6: `ImageLoader` is non-Sendable, so capturing it directly in
        // the @Sendable global-queue closure is "sending self.loader". Box it in
        // LockIsolated (Sendable) and read `.value` inside the closure.
        let loaderBox = LockIsolated(loader!)
        DispatchQueue.global().async {
            loaderBox.value.thumbnailImage(for: book) { _ in
                ranOnMain.value = Thread.isMainThread
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(ranOnMain.value, "Bridge completion must fire on the main thread")
    }

    func testCompletionBridge_cover_invokesOnMainThread() {
        let book = makeBook()
        let expectation = expectation(description: "cover completion fires")
        let ranOnMain = MainThreadFlag()

        // Swift 6: box the non-Sendable loader (see sibling test) so it can be
        // read inside the @Sendable global-queue closure without "sending".
        let loaderBox = LockIsolated(loader!)
        DispatchQueue.global().async {
            loaderBox.value.coverImage(for: book) { _ in
                ranOnMain.value = Thread.isMainThread
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(ranOnMain.value)
    }

    func testCompletionBridge_book_deallocatedBeforeCompletion_noCrash() {
        // Repro the EXC_BAD_ACCESS pattern the old bridge guarded against:
        // hand the loader a book reference, drop our strong ref immediately,
        // and let the completion fire after dealloc.
        let expectation = expectation(description: "callback fires safely")
        autoreleasepool {
            let book = makeBook()
            loader.thumbnailImage(for: book) { _ in
                expectation.fulfill()
            }
            // book leaves scope here — the loader must have captured its
            // URLs synchronously, not retained the book strongly.
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Cache surface re-export

    func testClearAll_clearsUnderlyingImageCache() {
        cache.set(makeImage(), for: "k1", expiresIn: nil)
        cache.set(makeImage(), for: "k2", expiresIn: nil)
        XCTAssertNotNil(cache.get(for: "k1"))

        loader.clearAll()

        XCTAssertTrue(cache.cleared, "clearAll must call through to ImageCacheType.clear()")
        XCTAssertNil(cache.get(for: "k1"))
        XCTAssertNil(cache.get(for: "k2"))
    }

    func testGetSet_delegateToUnderlyingCache() {
        let img = makeImage(color: .yellow)
        loader.set(img, for: "the-key", expiresIn: 60)

        XCTAssertEqual(loader.get(for: "the-key")?.pngData(), img.pngData())
        XCTAssertEqual(cache.setKeys, ["the-key"])
    }

    func testRemove_delegateToUnderlyingCache() {
        cache.set(makeImage(), for: "rm", expiresIn: nil)
        XCTAssertNotNil(loader.get(for: "rm"))

        loader.remove(for: "rm")

        XCTAssertNil(loader.get(for: "rm"))
        XCTAssertEqual(cache.removedKeys, ["rm"])
    }

    func testSet_defaultExpiry_isSevenDays() {
        // The protocol extension defaults to 7d expiry when no value is given.
        let img = makeImage()
        let before = Date()
        loader.set(img, for: "ttl")

        // The MockImageCache records `expiresIn` indirectly via the expirations
        // it computes. Re-read with `now` set 6d into the future — still cached;
        // bump 8d — gone.
        cache.now = before.addingTimeInterval(6 * 24 * 60 * 60)
        XCTAssertNotNil(cache.get(for: "ttl"))

        cache.now = before.addingTimeInterval(8 * 24 * 60 * 60)
        XCTAssertNil(cache.get(for: "ttl"))
    }

    // MARK: - Static utility passthrough

    func testDownsampleImage_returnsImageWithinMaxDimension() {
        // Sanity-check that the static decode utility the loader composes
        // still produces an image bounded by maxDimension. Mutation surface:
        // if `maxDimension` ever stops feeding into kCGImageSourceThumbnailMaxPixelSize,
        // this test catches it.
        let bigImage = makeImage(width: 200, height: 200)
        guard let jpegData = bigImage.jpegData(compressionQuality: 0.9) else {
            XCTFail("Failed to encode test image")
            return
        }

        let result = TPPBookCoverRegistry.downsampleImage(data: jpegData, maxDimension: 64)

        XCTAssertNotNil(result)
        let maxSide = max(result!.size.width, result!.size.height)
        XCTAssertLessThanOrEqual(maxSide, 64, "downsampled side must not exceed maxDimension")
    }

    // MARK: - PP-4772 / 077218fc — non-finite display dimensions must not trap

    /// The sanitizer that guards every `Int(displayDimension)` conversion in the
    /// cover pipeline. Keeps finite positive values; rejects the NaN / infinite /
    /// non-positive sizes a view can report mid-layout (the EXC_BREAKPOINT source).
    func testFinitePositiveDimension_keepsFinitePositive_rejectsEverythingElse() {
        XCTAssertEqual(CGFloat(120).finitePositiveDimension, 120)
        XCTAssertEqual(CGFloat(0.5).finitePositiveDimension, 0.5)
        XCTAssertNil(CGFloat.nan.finitePositiveDimension)
        XCTAssertNil(CGFloat.infinity.finitePositiveDimension)
        XCTAssertNil((-CGFloat.infinity).finitePositiveDimension)
        XCTAssertNil(CGFloat(0).finitePositiveDimension)
        XCTAssertNil(CGFloat(-5).finitePositiveDimension)
    }

    /// Regression for Crashlytics 077218fc: `ImageLoader.coverImage(for:displayPoints:)`
    /// computed `Int(min(displayPoints * scale * 1.5, 1200))` for its cache key. When a
    /// view reported a NaN / infinite / non-positive height, that `Int(_:)` conversion
    /// trapped with EXC_BREAKPOINT. The loader must instead fall back to the unsized
    /// cover. Pre-loading the unsized cover key makes the fallback deterministic (no
    /// network, no TenPrint).
    func testCoverImage_displayPoints_nonFinite_fallsBackToUnsizedCover_withoutTrapping() async {
        // Give the book a non-nil imageURL. `TPPBook.init` fires a fire-and-forget
        // `fetchCoverImage()`; for a URL-*less* book that path instantly generates a
        // TenPrint placeholder and writes it into THIS mock cache under `_cover`,
        // asynchronously clobbering the seeded sentinel mid-loop (the flake this test
        // exhibited: iter 1 saw the sentinel, iters 2-5 saw the placeholder). With a
        // URL, that init fetch takes the never-completing network path in-test, so the
        // sentinel stays put. The sanitizer under test hits the `_cover` cache and
        // short-circuits before any network/registry access, so the URL does not
        // affect what the fallback returns — only which write wins the seed race.
        let book = makeBook(imageURL: URL(string: "https://example.com/cover.jpg")!)
        let sentinel = makeImage(width: 10, height: 10)
        cache.set(sentinel, for: "\(book.identifier)_cover", expiresIn: nil)

        for bad: CGFloat in [.nan, .infinity, -.infinity, 0, -5] {
            // Pre-fix, the next line traps before returning.
            let result = await loader.coverImage(for: book, displayPoints: bad)
            XCTAssertEqual(result?.pngData(), sentinel.pngData(),
                           "displayPoints=\(bad) must fall back to the unsized cover, not trap")
        }
    }

    /// Same regression one layer down, at the registry seam the loader composes.
    /// `TPPBookCoverRegistry.coverImage(for:displayPoints:)` had the identical
    /// unguarded `Int(neededPixels)` conversion.
    func testRegistryCoverImage_displayPoints_nonFinite_fallsBackToUnsizedCover_withoutTrapping() async {
        let registry = TPPBookCoverRegistry(imageCache: cache)
        let book = makeBook(imageURL: URL(string: "https://example.com/cover.jpg")!)
        let sentinel = makeImage(width: 10, height: 10)
        cache.set(sentinel, for: "\(book.identifier)_cover", expiresIn: nil)

        for bad: CGFloat in [.nan, .infinity, 0, -5] {
            let result = await registry.coverImage(for: book, displayPoints: bad)
            XCTAssertEqual(result?.pngData(), sentinel.pngData(),
                           "registry displayPoints=\(bad) must fall back to the unsized cover, not trap")
        }
    }
}
