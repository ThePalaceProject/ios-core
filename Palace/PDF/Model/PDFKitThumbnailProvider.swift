//
//  PDFKitThumbnailProvider.swift
//  Palace
//
//  PP-1916: on-demand PDF page thumbnail provider.
//
//  PDFKit's `PDFThumbnailView` rasterizes a thumbnail for *every* page the
//  moment it's handed a document — on a large title that is slow and crashes.
//  This provider renders a page's thumbnail only when asked and caches the
//  result, so `PDFThumbnailStrip` can drive it from a `LazyHStack` that only
//  requests the pages currently on screen.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import PDFKit
import UIKit

/// Lazily renders and caches PDF page thumbnails on demand.
///
/// `ObservableObject` so a SwiftUI view can own a stable instance via
/// `@StateObject` across re-renders; it publishes nothing itself — per-cell
/// updates are driven by the strip's own fetchers.
final class PDFKitThumbnailProvider: ObservableObject {

    private let document: PDFDocument
    private let thumbnailSize: CGSize
    private let cache: CountedCache<Int, UIImage>

    /// Bytes of every provider's thumbnails; a provider is made per document.
    nonisolated static let liveThumbnailBytes = CacheByteCounter()

    init(
        document: PDFDocument,
        thumbnailSize: CGSize = .pdfThumbnailSize,
        byteCounter: CacheByteCounter = PDFKitThumbnailProvider.liveThumbnailBytes
    ) {
        self.document = document
        self.thumbnailSize = thumbnailSize
        cache = CountedCache(counter: byteCounter)
        cache.countLimit = 64
    }

    /// Total number of pages in the backing document.
    var pageCount: Int { document.pageCount }

    /// Returns a previously rendered thumbnail if one is cached, without
    /// triggering a render. Lets the strip show a placeholder immediately.
    func cachedThumbnail(for page: Int) -> UIImage? {
        cache.object(forKey: page)
    }

    /// Renders (or returns the cached) thumbnail for `page`. Safe to call off
    /// the main thread. Returns `nil` for out-of-range pages.
    func thumbnail(for page: Int) -> UIImage? {
        guard page >= 0, page < document.pageCount else { return nil }
        if let cached = cache.object(forKey: page) { return cached }
        guard let image = document.page(at: page)?.thumbnail(of: thumbnailSize, for: .mediaBox) else {
            return nil
        }
        cache.setObject(image, forKey: page, cost: 0, bytes: image.decodedByteCount)
        return image
    }
}
