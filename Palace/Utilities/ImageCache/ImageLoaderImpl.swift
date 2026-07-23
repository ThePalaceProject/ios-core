import UIKit
import PalaceLogging
import PalaceBookModel

/// Transports the non-`Sendable` completion handler across the `@Sendable`
/// `Task` boundary in the Obj-C/completion-style bridge methods. The wrapped
/// closure is ONLY ever invoked inside `await MainActor.run { ... }` — never
/// off the main actor and never concurrently — so `@unchecked Sendable` is
/// sound: the box merely satisfies the capture check without changing the
/// `ImageLoading` protocol's public signature (which would ripple `@Sendable`
/// to every completion-handler call site).
private final class ImageCompletionBox: @unchecked Sendable {
    let call: (UIImage?) -> Void
    init(_ call: @escaping (UIImage?) -> Void) { self.call = call }
}

/// Concrete `ImageLoading` implementation. Composes the existing
/// `TPPBookCoverRegistry` actor (which still owns the source-bytes cache,
/// circuit breaker, decode pipeline, and TenPrint placeholder generation) with
/// an `ImageCacheType` (the disk + decoded-memory layer).
///
/// This is the ONE umbrella callers see. The two underlying primitives stay
/// internal — `ImageLoader` is the only thing that knows the registry and the
/// cache should be talked to together.
///
/// Not `final` so test subclasses can override individual hooks if needed —
/// per CLAUDE.md "don't make new services final reflexively".
///
/// `nonisolated` is load-bearing (Wave 2a), for the same empirical reason as
/// `ImageCache`: moving the `ImageLoading` protocol out of this app-target
/// module into the `PalaceBookModel` package changed this conformer's inferred
/// isolation. That flip stamped a main-executor precondition onto the class —
/// so constructing it synchronously off the main actor (`_buildCachedAppContainer`
/// is a nonisolated `static func`, and `AccountsManager`'s background
/// `loadCatalogs` runs alongside it) tripped `dispatch_assert_queue` →
/// EXC_BREAKPOINT (SIGTRAP) at launch, crashing the test host before any test
/// ran. This class is genuinely off-main-safe — every stored property is an
/// immutable `let` (an actor-backed `TPPBookCoverRegistry` + a `Sendable`
/// `ImageCacheType`), it holds no mutable state, and every main-only touch
/// (`UIScreen.main.scale`, the completion callbacks) is already an explicit
/// `await MainActor.run` hop — so `nonisolated` restores the pre-extraction
/// base behavior exactly rather than papering over a real main-thread need.
public nonisolated class ImageLoader: ImageLoading, @unchecked Sendable {
    // @unchecked Sendable: only immutable `let` collaborators (an actor-backed
    // registry + a shared cache), no mutable state — safe to reference across
    // concurrency domains (its async methods are awaited from @MainActor tests).


    // MARK: - Composition

    /// Underlying actor that handles network fetch, source-bytes caching, host
    /// circuit breaker, decode-at-display-size, and TenPrint placeholders.
    /// Kept internal so call sites can't reach past `ImageLoading`.
    private let registry: TPPBookCoverRegistry

    /// Disk + decoded-memory cache. Re-exported through the cache surface of
    /// `ImageLoading` so consumers that used to inject `ImageCacheType` get one
    /// protocol covering both layers.
    private let cache: ImageCacheType

    // MARK: - Init

    public init(imageCache: ImageCacheType) {
        self.cache = imageCache
        self.registry = TPPBookCoverRegistry(imageCache: imageCache)
    }

    // MARK: - Book-level fetch

    /// Returns the cached cover image if already populated, otherwise delegates
    /// to the registry's full fetch+decode pipeline. The cache short-circuit
    /// avoids re-fetching+re-decoding when a consumer (BookListView, etc.)
    /// already populated the umbrella cache under the standard cover key.
    public func coverImage(for book: TPPBook) async -> UIImage? {
        let coverKey = "\(book.identifier)_cover"
        if let cached = cache.get(for: coverKey) {
            return cached
        }
        return await registry.coverImage(for: book)
    }

    /// Returns the cached cover image at the display size if already populated,
    /// otherwise delegates to the registry. Matches the registry's keying
    /// (`<identifier>_<px>px`) so a cache pre-warmed by an earlier read at the
    /// same display height is honored without re-fetch.
    public func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? {
        // A non-finite / non-positive display size (a view mid-layout) would trap at
        // `Int(neededPixels)` below. Fall back to the unsized cover. PP-4772 / 077218fc.
        guard let displayPoints = displayPoints.finitePositiveDimension else {
            return await coverImage(for: book)
        }
        let scale = await MainActor.run { UIScreen.main.scale }
        let neededPixels = min(displayPoints * scale * 1.5, 1200)
        let key = "\(book.identifier)_\(Int(neededPixels))px"
        if let cached = cache.get(for: key) {
            return cached
        }
        return await registry.coverImage(for: book, displayPoints: displayPoints)
    }

    public func thumbnailImage(for book: TPPBook) async -> UIImage? {
        await registry.thumbnailImage(for: book)
    }

    public func playerCoverImage(for book: TPPBook) async -> UIImage? {
        await registry.playerCoverImage(for: book)
    }

    // MARK: - Obj-C / completion-style bridge
    //
    // Capture every value the fetch needs synchronously (URLs, identifier,
    // title, authors) — never touch `book` after the Task starts. This is the
    // weak-book-reference safety the old TPPBookCoverRegistryBridge guaranteed
    // against EXC_BAD_ACCESS when the book deallocates mid-fetch.

    public func coverImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        let bookIdentifier = book.identifier
        let coverKey = "\(bookIdentifier)_cover"
        let imageURL = book.imageURL
        let thumbnailURL = book.imageThumbnailURL
        let title = book.title
        let authors = book.authors
        let cache = self.cache
        let registry = self.registry
        let completionBox = ImageCompletionBox(completion)

        Task { [weak book] in
            var image: UIImage?
            if let url = imageURL {
                image = await registry.fetchImageByURL(url, identifier: bookIdentifier, isCover: true)
            }
            if image == nil, let url = thumbnailURL {
                image = await registry.fetchImageByURL(url, identifier: bookIdentifier, isCover: false)
            }
            if image == nil {
                image = await registry.generatePlaceholder(title: title, authors: authors)
            }

            let finalImage = image
            let capturedBook = book
            await MainActor.run {
                if let finalImage {
                    // Two DISTINCT cache references, not a duplicate write: `cache`
                    // is this loader's injected `ImageCacheType` (what `coverImage(for:)`
                    // reads), and `capturedBook?.imageCache` is the book's own cache
                    // (what `TPPBook.fetchCoverImage`'s sync check reads). They are the
                    // same object ONLY when both were built with `ImageCache.shared`
                    // (the production convention) — the two injection points are
                    // independent (AppContainer vs. TPPBook.init), so identity is not
                    // structurally guaranteed and neither set is safely removable.
                    cache.set(finalImage, for: coverKey)
                    capturedBook?.imageCache.set(finalImage, for: coverKey)
                }
                completionBox.call(finalImage)
            }
        }
    }

    public func thumbnailImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        let bookIdentifier = book.identifier
        let thumbnailKey = "\(bookIdentifier)_thumbnail"
        let thumbnailURL = book.imageThumbnailURL
        let title = book.title
        let authors = book.authors
        let cache = self.cache
        let registry = self.registry
        let completionBox = ImageCompletionBox(completion)

        Task { [weak book] in
            var image: UIImage?
            if let url = thumbnailURL {
                image = await registry.fetchImageByURL(url, identifier: bookIdentifier, isCover: false)
            }
            if image == nil {
                image = await registry.generatePlaceholder(title: title, authors: authors)
            }

            let finalImage = image
            let capturedBook = book
            await MainActor.run {
                if let finalImage {
                    // Distinct cache references (see `coverImage(for:completion:)`):
                    // loader-injected `cache` vs. the book's own `imageCache`.
                    // Identical only under the `ImageCache.shared` convention; the
                    // independent injection points mean neither set is safely removable.
                    cache.set(finalImage, for: thumbnailKey)
                    capturedBook?.imageCache.set(finalImage, for: thumbnailKey)
                }
                completionBox.call(finalImage)
            }
        }
    }

    // MARK: - Cache surface re-export

    public func get(for key: String) -> UIImage? {
        cache.get(for: key)
    }

    public func getAsync(for key: String) async -> UIImage? {
        await cache.getAsync(for: key)
    }

    public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {
        cache.set(image, for: key, expiresIn: expiresIn)
    }

    public func remove(for key: String) {
        cache.remove(for: key)
    }

    public func clearAll() {
        cache.clear()
    }

    public func evictDecodedImages() {
        // `evictDecodedImages` only exists on the concrete `ImageCache` class
        // today, not on `ImageCacheType`. Cast when present; otherwise fall back
        // to a full clear (test mocks override `clearAll`/`evictDecodedImages`
        // independently so they can still distinguish the two).
        if let concrete = cache as? ImageCache {
            concrete.evictDecodedImages()
        } else {
            cache.clear()
        }
    }

    public func warmMemoryCache(for keys: [String]) async {
        await cache.warmMemoryCache(for: keys)
    }
}
