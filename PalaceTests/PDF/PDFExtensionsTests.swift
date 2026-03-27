//
//  PDFExtensionsTests.swift
//  PalaceTests
//
//  Tests for PDF-related extensions: CGSize, DispatchQueue,
//  TPPBookLocation+pageNumber, TPPPDFPage+serialization.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class PDFExtensionsTests: XCTestCase {

    // MARK: - CGSize Extension Tests

    /// SRS: PDF-001 — Thumbnail size is consistent for PDF viewer grid
    func testPdfThumbnailSize_ReturnsExpectedDimensions() {
        let size = CGSize.pdfThumbnailSize
        XCTAssertEqual(size.width, 30)
        XCTAssertEqual(size.height, 30)
    }

    /// SRS: PDF-001 — Preview size is consistent for PDF viewer
    func testPdfPreviewSize_ReturnsExpectedDimensions() {
        let size = CGSize.pdfPreviewSize
        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 300)
    }

    func testPdfThumbnailSize_IsSquare() {
        let size = CGSize.pdfThumbnailSize
        XCTAssertEqual(size.width, size.height)
    }

    func testPdfPreviewSize_IsSquare() {
        let size = CGSize.pdfPreviewSize
        XCTAssertEqual(size.width, size.height)
    }

    func testPdfPreviewSize_IsLargerThanThumbnail() {
        let thumbnail = CGSize.pdfThumbnailSize
        let preview = CGSize.pdfPreviewSize
        XCTAssertGreaterThan(preview.width, thumbnail.width)
        XCTAssertGreaterThan(preview.height, thumbnail.height)
    }

    // MARK: - DispatchQueue Extension Tests

    func testPdfThumbnailRenderingQueue_HasCorrectLabel() {
        let queue = DispatchQueue.pdfThumbnailRenderingQueue
        XCTAssertEqual(queue.label, "org.thepalaceproject.palace.thumbnailRenderingQueue")
    }

    func testPdfImageRenderingQueue_HasCorrectLabel() {
        let queue = DispatchQueue.pdfImageRenderingQueue
        XCTAssertEqual(queue.label, "org.thepalaceproject.palace.imageRenderingQueue")
    }

    func testPdfThumbnailRenderingQueue_CreatesNewInstanceEachTime() {
        let queue1 = DispatchQueue.pdfThumbnailRenderingQueue
        let queue2 = DispatchQueue.pdfThumbnailRenderingQueue
        // Each call creates a new dispatch queue (computed property)
        XCTAssertFalse(queue1 === queue2)
    }

    func testPdfImageRenderingQueue_CreatesNewInstanceEachTime() {
        let queue1 = DispatchQueue.pdfImageRenderingQueue
        let queue2 = DispatchQueue.pdfImageRenderingQueue
        XCTAssertFalse(queue1 === queue2)
    }

    // MARK: - TPPPDFPage+serialization Tests

    /// SRS: PDF-004 — Page navigation updates position
    func testLocationString_ValidPage_ReturnsJSONString() {
        let page = TPPPDFPage(pageNumber: 42)
        let locationString = page.locationString

        XCTAssertNotNil(locationString)
        XCTAssertTrue(locationString!.contains("42"))
        XCTAssertTrue(locationString!.contains("pageNumber"))
    }

    func testLocationString_PageZero_ReturnsValidJSON() {
        let page = TPPPDFPage(pageNumber: 0)
        let locationString = page.locationString

        XCTAssertNotNil(locationString)
        XCTAssertTrue(locationString!.contains("0"))
    }

    func testLocationString_RoundTrips_WithDecoder() throws {
        let page = TPPPDFPage(pageNumber: 99)
        let locationString = page.locationString!

        let data = locationString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TPPPDFPage.self, from: data)

        XCTAssertEqual(decoded.pageNumber, 99)
    }

    func testBookmarkSelector_ValidPage_ContainsLocatorPageType() {
        let page = TPPPDFPage(pageNumber: 10)
        let selector = page.bookmarkSelector

        XCTAssertNotNil(selector)
        XCTAssertTrue(selector!.contains("LocatorPage"))
        XCTAssertTrue(selector!.contains("10"))
    }

    func testBookmarkSelector_RoundTrips_AsTPPPDFPageBookmark() throws {
        let page = TPPPDFPage(pageNumber: 7)
        let selector = page.bookmarkSelector!

        let data = selector.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TPPPDFPageBookmark.self, from: data)

        XCTAssertEqual(decoded.page, 7)
        XCTAssertEqual(decoded.type, "LocatorPage")
    }

    // MARK: - TPPBookLocation+pageNumber Tests

    /// SRS: PDF-004 — Page navigation updates position
    func testPageNumber_ValidLocationString_ReturnsPageNumber() {
        let page = TPPPDFPage(pageNumber: 25)
        let locationString = page.locationString!
        let bookLocation = TPPBookLocation(locationString: locationString, renderer: "pdf")

        XCTAssertNotNil(bookLocation)
        XCTAssertEqual(bookLocation?.pageNumber, 25)
    }

    func testPageNumber_InvalidLocationString_ReturnsNil() {
        let bookLocation = TPPBookLocation(locationString: "not-json", renderer: "pdf")

        XCTAssertNil(bookLocation?.pageNumber)
    }

    func testPageNumber_EmptyLocationString_ReturnsNil() {
        let bookLocation = TPPBookLocation(locationString: "", renderer: "pdf")

        XCTAssertNil(bookLocation?.pageNumber)
    }

    func testPageNumber_NonPDFLocationString_ReturnsNil() {
        let bookLocation = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "readium")

        XCTAssertNil(bookLocation?.pageNumber)
    }

    func testPageNumber_PageZero_ReturnsZero() {
        let page = TPPPDFPage(pageNumber: 0)
        let locationString = page.locationString!
        let bookLocation = TPPBookLocation(locationString: locationString, renderer: "pdf")

        XCTAssertEqual(bookLocation?.pageNumber, 0)
    }

    func testPageNumber_LargePageNumber_ReturnsCorrectly() {
        let page = TPPPDFPage(pageNumber: 99999)
        let locationString = page.locationString!
        let bookLocation = TPPBookLocation(locationString: locationString, renderer: "pdf")

        XCTAssertEqual(bookLocation?.pageNumber, 99999)
    }
}
