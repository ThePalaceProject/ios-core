//
//  PDFKitThumbnailProviderTests.swift
//  PalaceTests
//
//  PP-1916: the bottom thumbnail strip must render thumbnails lazily/on-demand
//  rather than rasterizing every page up front. These tests pin the provider's
//  on-demand caching + bounds contract that makes that possible.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PDFKit
@testable import Palace

@MainActor
final class PDFKitThumbnailProviderTests: XCTestCase {

    /// Build an in-memory PDF with `pageCount` US-letter pages.
    private func makePDF(pageCount: Int) -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { ctx in
            for page in 0..<pageCount {
                ctx.beginPage()
                UIColor.white.setFill()
                ctx.fill(bounds)
                ("\(page + 1)" as NSString).draw(at: CGPoint(x: 40, y: 40),
                                                  withAttributes: [.font: UIFont.systemFont(ofSize: 48)])
            }
        }
        return PDFDocument(data: data)!
    }

    func testPageCount_reflectsDocument() {
        let provider = PDFKitThumbnailProvider(document: makePDF(pageCount: 7))
        XCTAssertEqual(provider.pageCount, 7)
    }

    func testCachedThumbnail_isNil_beforeAnyRender() {
        let provider = PDFKitThumbnailProvider(document: makePDF(pageCount: 3))
        // Nothing rendered yet → nothing cached. This is what lets the strip
        // show a placeholder instantly without forcing a render.
        XCTAssertNil(provider.cachedThumbnail(for: 0))
        XCTAssertNil(provider.cachedThumbnail(for: 2))
    }

    func testThumbnail_rendersAndCaches() {
        let provider = PDFKitThumbnailProvider(document: makePDF(pageCount: 3))

        let rendered = provider.thumbnail(for: 1)
        XCTAssertNotNil(rendered, "A valid page should render a thumbnail")

        // After a render the page is cached and returned without re-rendering.
        let cached = provider.cachedThumbnail(for: 1)
        XCTAssertNotNil(cached, "Rendered thumbnail should be cached")
        XCTAssertTrue(cached === rendered, "Cache should return the same instance, not re-render")

        // A page that was never requested stays uncached — proof rendering is
        // on-demand per page, not an all-pages pass (PP-1916).
        XCTAssertNil(provider.cachedThumbnail(for: 0))
        XCTAssertNil(provider.cachedThumbnail(for: 2))
    }

    func testThumbnail_outOfBounds_returnsNilAndDoesNotCache() {
        let provider = PDFKitThumbnailProvider(document: makePDF(pageCount: 3))

        XCTAssertNil(provider.thumbnail(for: 3), "page == pageCount is out of bounds")
        XCTAssertNil(provider.thumbnail(for: 99))
        XCTAssertNil(provider.thumbnail(for: -1), "negative index is out of bounds")

        XCTAssertNil(provider.cachedThumbnail(for: 3))
        XCTAssertNil(provider.cachedThumbnail(for: -1))
    }

    func testThumbnail_lastValidPage_renders() {
        let provider = PDFKitThumbnailProvider(document: makePDF(pageCount: 4))
        // Boundary: pageCount - 1 must be valid (kills an off-by-one in the
        // upper-bound check).
        XCTAssertNotNil(provider.thumbnail(for: 3))
    }
}
