//
//  ErrorDetailViewControllerTests.swift
//  PalaceTests
//
//  Tests for ErrorDetailViewController: renderContent (addField, addLine, addSection).
//  Covers High-priority coverage gaps: addField, addLine, addSection.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ErrorDetailViewControllerTests: XCTestCase {

    // MARK: - ErrorDetail Model Tests

    func testErrorDetail_FormattedReport_ContainsTitle() {
        let detail = makeErrorDetail(title: "Test Error", message: "Something went wrong")
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("Test Error"))
    }

    func testErrorDetail_FormattedReport_ContainsMessage() {
        let detail = makeErrorDetail(title: "Error", message: "A detailed message")
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("A detailed message"))
    }

    func testErrorDetail_FormattedReport_ContainsErrorHeader() {
        let detail = makeErrorDetail()
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("── Error ──"))
    }

    func testErrorDetail_FormattedReport_ContainsDeviceSection() {
        let detail = makeErrorDetail()
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("── Device ──"))
    }

    func testErrorDetail_FormattedReport_ContainsActivityTrailSection() {
        let detail = makeErrorDetail()
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("Activity Trail"))
    }

    func testErrorDetail_FormattedReport_WithUnderlyingError_ContainsDomain() {
        let error = NSError(domain: "com.test.error", code: 42, userInfo: nil)
        let detail = makeErrorDetail(error: error)
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("com.test.error"))
        XCTAssertTrue(report.contains("42"))
    }

    func testErrorDetail_FormattedReport_WithBookInfo_ContainsBookSection() {
        let detail = makeErrorDetail(
            bookIdentifier: "book-123",
            bookTitle: "Test Book"
        )
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("── Book ──"))
        XCTAssertTrue(report.contains("book-123"))
        XCTAssertTrue(report.contains("Test Book"))
    }

    func testErrorDetail_FormattedReport_WithNoBookInfo_OmitsBookSection() {
        let detail = makeErrorDetail()
        let report = detail.formattedReport()

        XCTAssertFalse(report.contains("── Book ──"))
    }

    func testErrorDetail_FormattedReport_ContainsTimestamp() {
        let detail = makeErrorDetail()
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("Palace Error Report"))
        XCTAssertTrue(report.contains("Time:"))
    }

    func testErrorDetail_FormattedReport_DeviceContextFields() {
        let detail = makeErrorDetail()
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("App:"))
        XCTAssertTrue(report.contains("iOS:"))
        XCTAssertTrue(report.contains("Device:"))
        XCTAssertTrue(report.contains("Library:"))
        XCTAssertTrue(report.contains("Storage:"))
        XCTAssertTrue(report.contains("Memory:"))
    }

    func testErrorDetail_FormattedReport_EmptyActivityTrail() {
        let detail = makeErrorDetail()
        let report = detail.formattedReport()

        XCTAssertTrue(report.contains("Activity Trail (0 entries)"))
        XCTAssertTrue(report.contains("(no recent activity recorded)"))
    }

    // MARK: - ErrorDetailViewController Initialization Tests

    func testErrorDetailViewController_Init_SetsTitle() {
        let detail = makeErrorDetail()
        let vc = ErrorDetailViewController(errorDetail: detail)

        // Trigger viewDidLoad
        vc.loadViewIfNeeded()

        XCTAssertEqual(vc.title, "Error Details")
    }

    func testErrorDetailViewController_ViewDidLoad_HasTextView() {
        let detail = makeErrorDetail(title: "Test", message: "Message")
        let vc = ErrorDetailViewController(errorDetail: detail)

        vc.loadViewIfNeeded()

        // Verify the view hierarchy contains a text view with content
        let textView = vc.view.subviews.compactMap { $0 as? UITextView }.first
        XCTAssertNotNil(textView, "Should have a UITextView as subview")
        XCTAssertFalse(textView?.text.isEmpty ?? true, "Text view should have content")
    }

    func testErrorDetailViewController_RenderContent_ContainsErrorTitle() {
        let detail = makeErrorDetail(title: "Download Failed", message: "Network timeout")
        let vc = ErrorDetailViewController(errorDetail: detail)

        vc.loadViewIfNeeded()

        let textView = vc.view.subviews.compactMap { $0 as? UITextView }.first
        let text = textView?.attributedText.string ?? ""

        XCTAssertTrue(text.contains("Download Failed"), "Rendered content should contain error title (addField)")
        XCTAssertTrue(text.contains("Network timeout"), "Rendered content should contain error message (addField)")
    }

    func testErrorDetailViewController_RenderContent_ContainsSection() {
        let detail = makeErrorDetail()
        let vc = ErrorDetailViewController(errorDetail: detail)

        vc.loadViewIfNeeded()

        let textView = vc.view.subviews.compactMap { $0 as? UITextView }.first
        let text = textView?.attributedText.string ?? ""

        XCTAssertTrue(text.contains("Error"), "Should contain Error section (addSection)")
        XCTAssertTrue(text.contains("Device"), "Should contain Device section (addSection)")
    }

    func testErrorDetailViewController_RenderContent_ContainsDeviceFields() {
        let detail = makeErrorDetail()
        let vc = ErrorDetailViewController(errorDetail: detail)

        vc.loadViewIfNeeded()

        let textView = vc.view.subviews.compactMap { $0 as? UITextView }.first
        let text = textView?.attributedText.string ?? ""

        XCTAssertTrue(text.contains("App Version"), "Should contain App Version field (addField)")
        XCTAssertTrue(text.contains("iOS"), "Should contain iOS field (addField)")
    }

    func testErrorDetailViewController_RenderContent_EmptyTrailShowsMessage() {
        let detail = makeErrorDetail()
        let vc = ErrorDetailViewController(errorDetail: detail)

        vc.loadViewIfNeeded()

        let textView = vc.view.subviews.compactMap { $0 as? UITextView }.first
        let text = textView?.attributedText.string ?? ""

        XCTAssertTrue(text.contains("no recent activity recorded"), "Empty trail should show message (addLine)")
    }

    func testErrorDetailViewController_NavigationItems_AreConfigured() {
        let detail = makeErrorDetail()
        let vc = ErrorDetailViewController(errorDetail: detail)

        vc.loadViewIfNeeded()

        XCTAssertNotNil(vc.navigationItem.leftBarButtonItem, "Should have a Done button")
        XCTAssertNotNil(vc.navigationItem.rightBarButtonItems, "Should have action buttons")
        XCTAssertEqual(vc.navigationItem.rightBarButtonItems?.count, 2, "Should have share and copy buttons")
    }

    // MARK: - Helpers

    private func makeErrorDetail(
        title: String = "Error",
        message: String = "Something went wrong",
        error: Error? = nil,
        bookIdentifier: String? = nil,
        bookTitle: String? = nil
    ) -> ErrorDetail {
        let bookInfo: ErrorDetail.BookInfo? = bookIdentifier.map {
            ErrorDetail.BookInfo(identifier: $0, title: bookTitle)
        }

        return ErrorDetail(
            title: title,
            message: message,
            underlyingError: error,
            problemDocument: nil,
            activityTrail: [],
            timestamp: Date(),
            bookInfo: bookInfo,
            deviceContext: ErrorDetail.DeviceContext(
                appVersion: "2.0.0",
                buildNumber: "100",
                iosVersion: "18.0",
                deviceModel: "iPhone",
                libraryName: "Test Library",
                availableStorage: "50 GB",
                memoryUsage: "128 MB"
            )
        )
    }
}
