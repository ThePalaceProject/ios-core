//
//  ErrorDetailTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ErrorDetailTests: XCTestCase {

    // MARK: - Factory Method

    func testCapture_populatesBasicFields() async {
        let detail = await ErrorDetail.capture(
            title: "Test Error",
            message: "Something went wrong"
        )

        XCTAssertEqual(detail.title, "Test Error")
        XCTAssertEqual(detail.message, "Something went wrong")
        XCTAssertNil(detail.underlyingError)
        XCTAssertNil(detail.problemDocument)
        XCTAssertNil(detail.bookInfo)
        XCTAssertNotNil(detail.timestamp)
    }

    func testCapture_withError_storesUnderlyingError() async {
        let error = NSError(domain: "TestDomain", code: 42, userInfo: nil)
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Failed",
            error: error
        )

        XCTAssertNotNil(detail.underlyingError)
        let nsError = detail.underlyingError! as NSError
        XCTAssertEqual(nsError.domain, "TestDomain")
        XCTAssertEqual(nsError.code, 42)
    }

    func testCapture_withBookInfo_populatesBookContext() async {
        let detail = await ErrorDetail.capture(
            title: "Borrow Failed",
            message: "Error",
            bookIdentifier: "urn:isbn:123",
            bookTitle: "The Great Gatsby"
        )

        XCTAssertNotNil(detail.bookInfo)
        XCTAssertEqual(detail.bookInfo?.identifier, "urn:isbn:123")
        XCTAssertEqual(detail.bookInfo?.title, "The Great Gatsby")
    }

    func testCapture_withoutBookInfo_bookInfoIsNil() async {
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Generic error"
        )

        XCTAssertNil(detail.bookInfo)
    }

    // MARK: - Device Context

    func testCapture_populatesDeviceContext() async {
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Test"
        )

        let ctx = detail.deviceContext
        XCTAssertFalse(ctx.appVersion.isEmpty)
        XCTAssertFalse(ctx.buildNumber.isEmpty)
        XCTAssertFalse(ctx.iosVersion.isEmpty)
        XCTAssertFalse(ctx.deviceModel.isEmpty)
        XCTAssertFalse(ctx.availableStorage.isEmpty)
        XCTAssertFalse(ctx.memoryUsage.isEmpty)
    }

    // MARK: - Formatted Report

    func testFormattedReport_containsHeader() async {
        let detail = await ErrorDetail.capture(
            title: "Test Title",
            message: "Test Message"
        )

        let report = detail.formattedReport()
        XCTAssertTrue(report.contains("Palace Error Report"))
        XCTAssertTrue(report.contains("Time:"))
    }

    func testFormattedReport_containsErrorSection() async {
        let detail = await ErrorDetail.capture(
            title: "Borrow Failed",
            message: "Could not borrow"
        )

        let report = detail.formattedReport()
        XCTAssertTrue(report.contains("── Error ──"))
        XCTAssertTrue(report.contains("Title: Borrow Failed"))
        XCTAssertTrue(report.contains("Message: Could not borrow"))
    }

    func testFormattedReport_withError_containsErrorDetails() async {
        let error = NSError(
            domain: "TestDomain",
            code: 403,
            userInfo: [
                NSLocalizedDescriptionKey: "Forbidden",
                NSLocalizedRecoverySuggestionErrorKey: "Try again later"
            ]
        )
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Failed",
            error: error
        )

        let report = detail.formattedReport()
        XCTAssertTrue(report.contains("Domain: TestDomain"))
        XCTAssertTrue(report.contains("Code: 403"))
        XCTAssertTrue(report.contains("Recovery: Try again later"))
    }

    func testFormattedReport_withBookInfo_containsBookSection() async {
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Failed",
            bookIdentifier: "test-id",
            bookTitle: "My Book"
        )

        let report = detail.formattedReport()
        XCTAssertTrue(report.contains("── Book ──"))
        XCTAssertTrue(report.contains("ID: test-id"))
        XCTAssertTrue(report.contains("Title: My Book"))
    }

    func testFormattedReport_containsDeviceSection() async {
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Test"
        )

        let report = detail.formattedReport()
        XCTAssertTrue(report.contains("── Device ──"))
        XCTAssertTrue(report.contains("App:"))
        XCTAssertTrue(report.contains("iOS:"))
        XCTAssertTrue(report.contains("Device:"))
        XCTAssertTrue(report.contains("Storage:"))
        XCTAssertTrue(report.contains("Memory:"))
    }

    func testFormattedReport_containsActivityTrailSection() async {
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Test"
        )

        let report = detail.formattedReport()
        XCTAssertTrue(report.contains("── Activity Trail"))
    }

    // MARK: - BookInfo

    func testBookInfo_withNilIdentifier_isNil() async {
        let detail = await ErrorDetail.capture(
            title: "Error",
            message: "Test",
            bookIdentifier: nil,
            bookTitle: "Title Without ID"
        )

        XCTAssertNil(detail.bookInfo, "BookInfo should be nil when identifier is nil")
    }
}
