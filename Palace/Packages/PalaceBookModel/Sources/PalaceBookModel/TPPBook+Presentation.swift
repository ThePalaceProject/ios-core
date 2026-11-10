//
//  TPPBook+Presentation.swift
//  Palace
//
//  Extracted from TPPBook.swift
//  Computed UI properties: cover image fetching, dominant color,
//  display strings, and image cache management.
//

import Foundation
import UIKit

// MARK: - Cover Image Fetching & Cache

extension TPPBook {
    /// The loader configured on `TPPBookImageContext` at bootstrap, before any
    /// TPPBook exists. `nil` only in unit tests that never configure it, where
    /// the network fetches below no-op and the cache-hit paths still run.
    var imageLoader: ImageLoading? {
        TPPBookImageContext.imageLoader()
    }

    func fetchCoverImage() {
        fetchCoverImage(forDisplayHeight: nil)
    }

    /// Above this height (points) a cover view needs more pixels than a lane
    /// thumbnail. Matches `TPPBookCoverRegistry.smallDisplayThreshold`, which
    /// picks the thumbnail URL at or below it.
    static let largeCoverMinimumDisplayHeight: CGFloat = 200

    /// First cached image among `keys`, consulting the cache **exactly once per
    /// key**.
    ///
    /// This deliberately is not `keys.lazy.compactMap { cache.get(for: $0) }.first`.
    /// `LazySequenceProtocol.compactMap` expands to
    /// `map(transform).filter { $0 != nil }.map { $0! }`, so the transform runs
    /// twice per element — once for the filter's nil test and once for the
    /// trailing force-unwrap. A cache is mutable shared state: an entry present
    /// for the filter can be gone by the force-unwrap, and the unwrap then traps
    /// (`closure #2 in compactMap` in the crash report, reached from the lane
    /// prefetch in `CatalogContentView`). Reading each key once removes the
    /// disagreement the trap depends on.
    static func firstCachedImage(in cache: ImageCacheType, keys: [String]) -> UIImage? {
        for key in keys {
            if let image = cache.get(for: key) { return image }
        }
        return nil
    }

    /// Fetches the cover at a resolution appropriate for the given display height (in points).
    /// When `displayHeight` is provided, the decoded image is sized to match the view rather
    /// than the conservative device memory-tier cap, so the image is always sharp at its
    /// actual display size without wasting memory decoding more than needed.
    public func fetchCoverImage(forDisplayHeight displayHeight: CGFloat?) {
        // A view can hand back a NaN / infinite / non-positive height while it is
        // still laying out; `Int($0)` in the size key below would trap
        // (EXC_BREAKPOINT). Treat an unusable height as "no size" and take the
        // unsized path. PP-4772 / Crashlytics 077218fc.
        let displayHeight = displayHeight?.finitePositiveDimension
        let sizeKey: String? = displayHeight.map { "\(identifier)_\(Int($0))pt" }
        // The bare identifier usually holds a lane-sized thumbnail, so a large view
        // shows it only as a placeholder and always asks the loader, whose
        // registry caches real decodes by pixel size. The point-size key is not
        // read or written for large views: it can hold an offline fallback.
        let isLargeDisplay = (displayHeight ?? 0) > Self.largeCoverMinimumDisplayHeight
        let lookupKeys: [String] = if isLargeDisplay {
            []
        } else if let sizeKey {
            [sizeKey, identifier]
        } else {
            [identifier]
        }

        // Writes go to the store by ID, not through `self`: a sync can release
        // this object mid-fetch while its replacement waits on the same entry.
        let store = coverStore
        let key = coverStoreKey
        let cache = imageCache

        // Synchronous memory-cache check (instant, no disk I/O on main thread)
        if let img = Self.firstCachedImage(in: imageCache, keys: lookupKeys) {
            DispatchQueue.main.async {
                store.offerCover(img, for: key)
            }
            return
        }

        guard !isCoverLoading else { return }

        let placeholder = isLargeDisplay ? imageCache.get(for: identifier) : nil
        DispatchQueue.main.async {
            store.update(key) { $0.isCoverLoading = true }
            store.offerCover(placeholder, for: key)
        }

        if let displayHeight {
            Task { [weak self] in
                guard let self else {
                    await MainActor.run { store.update(key) { $0.isCoverLoading = false } }
                    return
                }

                // Async cache check: promotes disk→memory before hitting network.
                // This is the systemic fix for images "disappearing" on entry point
                // switches — new TPPBook instances miss the sync check above (main
                // thread returns nil for disk-only entries) but this async path finds
                // them without a network round-trip.
                for lookupKey in lookupKeys {
                    if let cached = await cache.getAsync(for: lookupKey) {
                        await MainActor.run {
                            store.offerCover(cached, for: key, endingLoad: true)
                        }
                        return
                    }
                }

                // Cache miss — fetch from network (no-op if the image context
                // is unconfigured, e.g. in a unit test).
                guard let imageLoader = self.imageLoader else {
                    await MainActor.run { store.update(key) { $0.isCoverLoading = false } }
                    return
                }
                let img = await imageLoader.coverImage(for: self, displayPoints: displayHeight)
                let final = img ?? placeholder ?? self.thumbnailImage
                await MainActor.run {
                    if let img = final, !isLargeDisplay {
                        cache.set(img, for: sizeKey ?? key)
                    }
                    store.offerCover(final, for: key, endingLoad: true)
                }
            }
        } else {
            let startFetch = { @Sendable [weak self] in
                guard let self, let imageLoader = self.imageLoader else {
                    DispatchQueue.main.async { store.update(key) { $0.isCoverLoading = false } }
                    return
                }

                imageLoader.coverImage(for: self) { image in
                    let final = image ?? store.state(for: key).thumbnailImage

                    DispatchQueue.main.async {
                        if let img = final {
                            // Single cache key — no duplicate storage
                            cache.set(img, for: key)
                        }
                        store.offerCover(final, for: key, endingLoad: true)
                    }
                }
            }

            if Thread.isMainThread {
                startFetch()
            } else {
                DispatchQueue.main.async(execute: startFetch)
            }
        }
    }

    func fetchThumbnailImage() {
        let store = coverStore
        let key = coverStoreKey
        let cache = imageCache
        let thumbnailKey = "\(identifier)_thumbnail"

        if let img = imageCache.get(for: identifier) ?? imageCache.get(for: thumbnailKey) {
            DispatchQueue.main.async {
                store.update(key) { $0.thumbnailImage = img }
            }
            return
        }

        let startFetch = { @Sendable [weak self] in
            guard let self, !self.isThumbnailLoading else { return }
            self.isThumbnailLoading = true

            guard let imageLoader = self.imageLoader else {
                DispatchQueue.main.async { store.update(key) { $0.isThumbnailLoading = false } }
                return
            }

            imageLoader.thumbnailImage(for: self) { image in
                DispatchQueue.main.async {
                    let hasCover = store.state(for: key).coverImage != nil
                    store.update(key) {
                        $0.thumbnailImage = image
                        $0.isThumbnailLoading = false
                    }
                    if let img = image {
                        cache.set(img, for: [key, thumbnailKey])
                        if !hasCover {
                            store.updateDominantColor(for: key, using: img)
                        }
                    }
                }
            }
        }

        if Thread.isMainThread {
            startFetch()
        } else {
            DispatchQueue.main.async(execute: startFetch)
        }
    }

    public func clearCachedImages() {
        imageCache.remove(for: identifier)
        imageCache.remove(for: "\(identifier)_cover")
        imageCache.remove(for: "\(identifier)_thumbnail")
        let store = coverStore
        let key = coverStoreKey
        DispatchQueue.main.async {
            store.update(key) {
                $0.coverImage = nil
                $0.thumbnailImage = nil
                $0.dominantColor = .gray
                $0.colorSource = nil
            }
        }
    }
}

// MARK: - Display Helpers

extension TPPBook {
    public var wrappedCoverImage: UIImage? {
        coverImage
    }

    public class func ordinalString(for n: Int) -> String {
        return n.ordinal()
    }
}

// MARK: - Dominant Color

extension TPPBook {
    /// Computes the cover color off the main thread, once per cover image for
    /// this book ID (see `BookCoverStore.updateDominantColor`).
    func updateDominantColor(using image: UIImage) {
        coverStore.updateDominantColor(for: coverStoreKey, using: image)
    }
}
