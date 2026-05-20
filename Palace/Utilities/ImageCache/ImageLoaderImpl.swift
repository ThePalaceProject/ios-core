import UIKit
import PalaceLogging

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
public class ImageLoader: ImageLoading {

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

    public func coverImage(for book: TPPBook) async -> UIImage? {
        await registry.coverImage(for: book)
    }

    public func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? {
        await registry.coverImage(for: book, displayPoints: displayPoints)
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
                    cache.set(finalImage, for: coverKey)
                    capturedBook?.imageCache.set(finalImage, for: coverKey)
                }
                completion(finalImage)
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
                    cache.set(finalImage, for: thumbnailKey)
                    capturedBook?.imageCache.set(finalImage, for: thumbnailKey)
                }
                completion(finalImage)
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
