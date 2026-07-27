import UIKit

/// Unified image-loading surface for the app. Replaces the trio of overlapping
/// singletons (`ImageCache.shared`, `TPPBookCoverRegistry.shared`,
/// `TPPBookCoverRegistryBridge.shared`) so call sites depend on ONE protocol
/// and inject it through `AppContainer` rather than reaching for `.shared`.
///
/// Layering:
///  - `coverImage` / `thumbnailImage` / `playerCoverImage` orchestrate network
///    fetch + decode + TenPrint placeholder fallback (formerly TPPBookCoverRegistry).
///  - The completion-handler `coverImage`/`thumbnailImage` overloads preserve
///    the Obj-C-friendly entry points the bridge used to expose, with the same
///    weak-book-reference safety pattern (capture URLs synchronously, allow the
///    book to dealloc mid-flight without crashing).
///  - The cache surface (`get`/`set`/`remove`/`clearAll`/`evictDecodedImages`/
///    `warmMemoryCache`) re-exports the disk+memory layer formerly named
///    `ImageCacheType` so a single injected `ImageLoading` covers every call
///    site that used to need both protocols.
public protocol ImageLoading: AnyObject {
    // MARK: - Book-level fetch (decode + cache + network)

    /// Fetches the cover URL for a book, falling back to the thumbnail URL if
    /// the cover fails. Decoded at the actor's device-tier max dimension.
    func coverImage(for book: TPPBook) async -> UIImage?

    /// Fetches the cover decoded at the minimum pixel size needed for the
    /// given display height in points. Bypasses the device memory-tier cap when
    /// a known display size is supplied so the image is sharp without
    /// over-fetching.
    func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage?

    /// Fetches the thumbnail URL only; renders a TenPrint placeholder when the
    /// network image is unavailable.
    func thumbnailImage(for book: TPPBook) async -> UIImage?

    /// Full-resolution variant for the audiobook player (screen-width decode,
    /// not memory-tier-capped).
    func playerCoverImage(for book: TPPBook) async -> UIImage?

    // MARK: - Obj-C / completion-style bridge (formerly TPPBookCoverRegistryBridge)

    /// Cover fetch with a completion handler invoked on the main thread.
    /// Captures the book's URLs synchronously so the book can dealloc during
    /// the fetch without crashing (the EXC_BAD_ACCESS pattern the old bridge
    /// guarded against).
    func coverImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void)

    /// Thumbnail fetch with a completion handler invoked on the main thread.
    /// Same weak-book-reference safety as `coverImage(for:completion:)`.
    func thumbnailImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void)

    // MARK: - Cache surface (formerly ImageCacheType)

    /// Synchronous memory-cache read. Returns nil on the main thread if the
    /// key is disk-only (a background promotion is scheduled in that case).
    func get(for key: String) -> UIImage?

    /// Async memory→disk promotion. Safe to call from the main actor.
    func getAsync(for key: String) async -> UIImage?

    /// Stores `image` under `key`, evicting the disk entry after `expiresIn`
    /// seconds (or the cache's default TTL if nil).
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?)

    /// Removes the entry for `key` from both memory and disk layers.
    func remove(for key: String)

    /// Drops every cached image (memory + disk).
    func clearAll()

    /// Evicts the decoded in-memory images without touching the JPEG-on-disk
    /// layer. Used on library switch to reclaim RAM while letting the next
    /// fetch promote from disk instead of re-hitting the network.
    func evictDecodedImages()

    /// Concurrent batch warm-up — promotes the given keys from disk into the
    /// memory cache before a screen-full of covers renders.
    func warmMemoryCache(for keys: [String]) async
}

public extension ImageLoading {
    /// Convenience overload using the default 7-day expiry.
    func set(_ image: UIImage, for key: String) {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        set(image, for: key, expiresIn: sevenDays)
    }
}
