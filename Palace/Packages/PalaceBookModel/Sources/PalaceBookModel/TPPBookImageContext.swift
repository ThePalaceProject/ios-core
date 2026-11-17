//
//  TPPBookImageContext.swift
//  PalaceBookModel
//
//  Image cache and loader providers for TPPBook, configured once by the
//  composition root before any TPPBook is constructed.
//  `nonisolated(unsafe)` is safe because both are written once (bootstrap or
//  test setUp) and read-only after. Unconfigured, the cache is an inert null
//  cache and the loader is nil, so constructing a TPPBook in a unit test does
//  not boot the production AppContainer.
//

import Foundation
import UIKit

public enum TPPBookImageContext {
    nonisolated(unsafe) public static var imageCacheProvider: (() -> ImageCacheType)?
    nonisolated(unsafe) public static var imageLoaderProvider: (() -> ImageLoading)?

    static func imageCache() -> ImageCacheType { imageCacheProvider?() ?? NullImageCache() }
    static func imageLoader() -> ImageLoading? { imageLoaderProvider?() }

    /// Test hygiene: reset both providers (call from tearDown in any test that sets them).
    public static func _resetForTesting() { imageCacheProvider = nil; imageLoaderProvider = nil }
}

/// Inert fallback so `TPPBook(dictionary:)`/`(entry:)` never trap when the
/// context is unconfigured. Never caches.
final class NullImageCache: ImageCacheType {
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {}
    func get(for key: String) -> UIImage? { nil }
    func getAsync(for key: String) async -> UIImage? { nil }
    func remove(for key: String) {}
    func clear() {}
    func warmMemoryCache(for keys: [String]) async {}
    func evictDecodedImages() {}
}
