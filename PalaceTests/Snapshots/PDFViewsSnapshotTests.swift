//
//  PDFViewsSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for PDF reader UI components.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class PDFViewsSnapshotTests: XCTestCase {

    // MARK: - TPPPDFPreviewThumbnail Tests

    func testPDFPreviewThumbnail_defaultSize() {
        let mockDocument = MockPDFDocument(pageCount: 10)
        let size = CGSize(width: 60, height: 80)

        let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
            .frame(width: size.width, height: size.height)
            .padding()
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 100, height: 120)
        XCTAssertEqual(mockDocument.pageCount, 10, "Document must have the expected page count")
    }

    func testPDFPreviewThumbnail_largerSize() {
        let mockDocument = MockPDFDocument(pageCount: 10)
        let size = CGSize(width: 90, height: 120)

        let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 5, size: size)
            .frame(width: size.width, height: size.height)
            .padding()
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 130, height: 160)
        XCTAssertTrue(size.width > 60, "Larger size must have width greater than the default 60pt thumbnail")
    }

    func testPDFPreviewThumbnail_smallSize() {
        let mockDocument = MockPDFDocument(pageCount: 10)
        let size = CGSize(width: 18, height: 24)

        let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
            .frame(width: size.width, height: size.height)
            .padding()
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 58, height: 64)
        XCTAssertTrue(size.width < 60, "Small size must have width less than the default 60pt thumbnail")
    }

    // MARK: - TPPPDFPreviewBar Tests

    func testPDFPreviewBar_atFirstPage() {
        let mockDocument = MockPDFDocument(pageCount: 20)

        let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(0))
            .frame(width: 390, height: 60)
            .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertEqual(mockDocument.pageCount, 20, "Document must expose its page count for the preview bar")
    }

    func testPDFPreviewBar_atMiddlePage() {
        let mockDocument = MockPDFDocument(pageCount: 20)

        let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(10))
            .frame(width: 390, height: 60)
            .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertEqual(mockDocument.pageCount, 20, "20-page document must still report pageCount = 20 at the middle page")
    }

    func testPDFPreviewBar_atLastPage() {
        let mockDocument = MockPDFDocument(pageCount: 20)

        let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(19))
            .frame(width: 390, height: 60)
            .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(mockDocument.pageCount > 0, "Document must have pages to display the preview bar")
    }

    func testPDFPreviewBar_compactWidth() {
        let mockDocument = MockPDFDocument(pageCount: 10)

        let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(5))
            .frame(width: 320, height: 60)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 320, height: 60)
        XCTAssertEqual(mockDocument.pageCount, 10, "Page count must remain 10 regardless of view width")
    }

    // MARK: - TPPPDFNavigation Tests

    func testPDFNavigation_readerMode_notBookmarked() {
        let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 5, bookmarks: [], isBookmarked: false)

        let view = TPPPDFNavigation(readerMode: .constant(.reader)) { mode in
            Text("Content for \(String(describing: mode))")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(metadata)
        .frame(width: 390, height: 100)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertFalse(metadata.isBookmarked(), "Page 5 must not be bookmarked in this test scenario")
    }

    func testPDFNavigation_readerMode_bookmarked() {
        let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 5, bookmarks: [5], isBookmarked: true)

        let view = TPPPDFNavigation(readerMode: .constant(.reader)) { mode in
            Text("Content for \(String(describing: mode))")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(metadata)
        .frame(width: 390, height: 100)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(metadata.isBookmarked(), "Current page must be bookmarked for this test scenario")
    }

    func testPDFNavigation_previewsMode() {
        let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)

        let view = TPPPDFNavigation(readerMode: .constant(.previews)) { _ in
            Text("Previews Content")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(metadata)
        .frame(width: 390, height: 100)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertEqual(metadata.currentPage, 0, "Previews mode must start at the first page in this test")
    }

    func testPDFNavigation_tocMode() {
        let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)

        let view = TPPPDFNavigation(readerMode: .constant(.toc)) { _ in
            Text("Table of Contents")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(metadata)
        .frame(width: 390, height: 100)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(metadata.bookmarks.isEmpty, "TOC mode test uses no bookmarks")
    }

    func testPDFNavigation_bookmarksMode() {
        let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [1, 5, 10], isBookmarked: false)

        let view = TPPPDFNavigation(readerMode: .constant(.bookmarks)) { _ in
            Text("Bookmarks List")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(metadata)
        .frame(width: 390, height: 100)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertEqual(metadata.bookmarks.count, 3, "Bookmarks mode must show all 3 bookmarked pages")
    }

    func testPDFNavigation_searchMode() {
        let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)

        let view = TPPPDFNavigation(readerMode: .constant(.search)) { _ in
            Text("Search Results")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(metadata)
        .frame(width: 390, height: 100)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(metadata.bookmarks.isEmpty, "Search mode test uses no bookmarks")
    }

    // MARK: - Dark Mode Tests

    func testPDFPreviewThumbnail_darkMode() {
        let mockDocument = MockPDFDocument(pageCount: 10)
        let size = CGSize(width: 60, height: 80)

        let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
            .frame(width: size.width, height: size.height)
            .padding()
            .background(Color(UIColor.systemBackground))
            .environment(\.colorScheme, .dark)

        assertFixedSizeSnapshot(of: view, width: 100, height: 120, userInterfaceStyle: .dark)
        XCTAssertEqual(mockDocument.pageCount, 10, "Dark mode must not change the document page count")
    }

    func testPDFPreviewBar_darkMode() {
        let mockDocument = MockPDFDocument(pageCount: 20)

        let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(10))
            .frame(width: 390, height: 60)
            .background(Color(UIColor.systemBackground))
            .environment(\.colorScheme, .dark)

        assertFixedSizeSnapshot(of: view, width: 390, height: 60, userInterfaceStyle: .dark)
        XCTAssertEqual(mockDocument.pageCount, 20, "Dark mode must not change the document page count")
    }
}
