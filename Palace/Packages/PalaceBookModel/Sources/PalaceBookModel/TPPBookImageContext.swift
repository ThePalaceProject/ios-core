//
//  TPPBookImageContext.swift
//  PalaceBookModel
//
//  Wave 2a inversion of TPPBook's two ambient image reaches
//  (`ImageCache.shared` in the convenience inits, `AppContainer.production()
//  .imageLoader` in the fetch extension). The composition root configures both
//  providers once at bootstrap, BEFORE any TPPBook is constructed.
//
//  `nonisolated(unsafe)` invariant (precedent: TPPAnnotations.
//  accountsManagerOverride): written exactly once during app bootstrap /
//  test setUp, read-only thereafter. Unconfigured (unit tests): the cache
//  falls back to an inert in-memory null cache and the loader to nil, which
//  turns TPPBook's init-time network fetches into no-ops — deliberately, so
//  constructing a TPPBook in a unit test no longer boots the production
//  AppContainer graph (a documented test-pollution vector).
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
}
