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

    /// `formattedReport()` produces the support-email body. Lock the
    /// header skeleton (Error / Device / Activity Trail sections), the
    /// pass-through of the supplied title and message, AND the section
    /// ordering in one body. A mutant that drops a section header or
    /// reorders sections fails on a single test.
    func testErrorDetail_FormattedReport_includesAllSectionsAndPassesThroughTitleAndMessage() {
        let detail = makeErrorDetail(title: "Test Error", message: "A detailed message")
        let report = detail.formattedReport()

        // Title + message pass through unchanged.
        XCTAssertTrue(report.contains("Test Error"),
                      "Title must pass through to the formatted report")
        XCTAssertTrue(report.contains("A detailed message"),
                      "Message must pass through to the formatted report")

        // Three required section headers are present.
        XCTAssertTrue(report.contains("── Error ──"),
                      "Error section header must be present")
        XCTAssertTrue(report.contains("── Device ──"),
                      "Device section header must be present")
        XCTAssertTrue(report.contains("Activity Trail"),
                      "Activity Trail section must be present")

        // Error must be the FIRST section — the user's actual error sits at
        // the top so engineers triaging the email see it without scrolling.
        guard
            let errorIdx = report.range(of: "── Error ──")?.lowerBound,
            let deviceIdx = report.range(of: "── Device ──")?.lowerBound
        else {
            XCTFail("Section markers must all be present"); return
        }
        XCTAssertLessThan(errorIdx, deviceIdx,
                          "Error section must precede Device — error context is more important than environment context")
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

    /// The Book section must appear iff the detail carries book info.
    /// Lock both branches in one test to guard against an "always-show" or
    /// "always-hide" mutant on the conditional rendering. The corresponding
    /// "WithBookInfo" test above already pins the present-section content;
    /// this one pins the absent-section side AND verifies the report still
    /// renders the other sections (so a mutant that crashes when book info
    /// is missing fails too).
    func testErrorDetail_FormattedReport_omitsBookSectionWhenNoBookInfoButRendersRestOfReport() {
        let report = makeErrorDetail().formattedReport()

        XCTAssertFalse(report.contains("── Book ──"),
                       "Book section header must NOT appear when no book info is supplied")
        XCTAssertFalse(report.contains("Book Title:"),
                       "Book Title field must NOT appear when no book info is supplied")
        // The rest of the report still renders — guards against an
        // early-return mutant in the rendering pipeline.
        XCTAssertTrue(report.contains("── Error ──"),
                      "Other sections must still render when book info is absent")
        XCTAssertTrue(report.contains("── Device ──"))
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

    /// Initialization wires the navigation title and the formatted report
    /// into the text view. The previous test only checked the title, but
    /// the title without a populated text view is meaningless to the user.
    /// Lock both at once so a mutant that bypasses the text-view rendering
    /// fails alongside one that swaps the title.
    func testErrorDetailViewController_Init_setsTitleAndPopulatesTextView() {
        let detail = makeErrorDetail(title: "Specific Error", message: "Inline copy")
        let vc = ErrorDetailViewController(errorDetail: detail)
        vc.loadViewIfNeeded()

        XCTAssertEqual(vc.title, "Error Details",
                       "Navigation title is the user-facing screen label")

        // Text view is the body — locate it and assert the formatted
        // report's title string actually made it into the rendered text.
        let textView = vc.view.subviews.compactMap { $0 as? UITextView }.first
        XCTAssertNotNil(textView, "View hierarchy must contain a UITextView")
        XCTAssertTrue(textView?.text.contains("Specific Error") ?? false,
                      "Text view must surface the supplied error title")
        XCTAssertTrue(textView?.text.contains("Inline copy") ?? false,
                      "Text view must surface the supplied error message")
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
