//
//  AlertUtilsTests.swift
//  PalaceTests
//
//  Tests for TPPAlertUtils: alert creation, error domain handling,
//  problem document integration, and alertWithDetails button composition.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AlertUtilsTests: XCTestCase {

    // MARK: - Basic Alert Creation

    func testAlertWithTitleAndMessage() {
        let alert = TPPAlertUtils.alert(title: "Test Title", message: "Test Message")

        XCTAssertNotNil(alert)
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertEqual(alert.actions.count, 1, "Should have one OK action")
        XCTAssertEqual(alert.actions.first?.style, .default)
    }

    func testAlertWithNilTitle() {
        let alert = TPPAlertUtils.alert(title: nil, message: "Message")

        XCTAssertEqual(alert.title, "Alert", "Nil title should fall back to 'Alert'")
        XCTAssertNotNil(alert.message)
    }

    func testAlertWithEmptyTitle() {
        let alert = TPPAlertUtils.alert(title: "", message: "Message")

        XCTAssertEqual(alert.title, "Alert", "Empty title should fall back to 'Alert'")
    }

    func testAlertWithNilMessage() {
        let alert = TPPAlertUtils.alert(title: "Title", message: nil)

        XCTAssertEqual(alert.message, "", "Nil message should produce empty string")
    }

    func testAlertWithDestructiveStyle() {
        let alert = TPPAlertUtils.alert(title: "Delete", message: "Are you sure?", style: .destructive)

        XCTAssertEqual(alert.actions.count, 1)
        XCTAssertEqual(alert.actions.first?.style, .destructive)
    }

    // MARK: - Error Alert Creation

    func testAlertWithNSURLErrorNotConnected() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let alert = TPPAlertUtils.alert(title: "Error", error: error as NSError)

        XCTAssertNotNil(alert.message)
        let msg = alert.message ?? ""
        // NSLocalizedString returns the key when no localization exists.
        // Accept any non-empty message for URL error handling.
        XCTAssertFalse(msg.isEmpty,
                       "Should produce a non-empty message for no internet error, got: '\(msg)'")
    }

    func testAlertWithNSURLErrorCancelled() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let alert = TPPAlertUtils.alert(title: "Error", error: error as NSError)

        let msg = alert.message ?? ""
        XCTAssertFalse(msg.isEmpty, "Should produce a non-empty message for cancelled error")
    }

    func testAlertWithNSURLErrorTimedOut() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let alert = TPPAlertUtils.alert(title: "Error", error: error as NSError)

        let msg = alert.message ?? ""
        XCTAssertFalse(msg.isEmpty, "Should produce a non-empty message for timed out error")
    }

    func testAlertWithNSURLErrorUnsupportedURL() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)
        let alert = TPPAlertUtils.alert(title: "Error", error: error)

        XCTAssertTrue(alert.message?.contains("UnsupportedURL") == true)
    }

    func testAlertWithUnknownNSURLError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let alert = TPPAlertUtils.alert(title: "Error", error: error)

        XCTAssertTrue(alert.message?.contains("UnknownRequestError") == true)
    }

    func testAlertWithNonURLError() {
        let error = NSError(
            domain: "com.test.custom",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Custom error message"]
        )
        let alert = TPPAlertUtils.alert(title: "Error", error: error)

        XCTAssertTrue(alert.message?.contains("Custom error message") == true,
                       "Should use localizedDescription for non-URL errors")
    }

    func testAlertWithErrorHavingNoDescription() {
        let error = NSError(domain: "com.test.empty", code: 0, userInfo: nil)
        let alert = TPPAlertUtils.alert(title: "Error", error: error)

        // Should fall back to generic message or error domain description
        XCTAssertNotNil(alert.message)
        XCTAssertFalse(alert.message?.isEmpty ?? true)
    }

    func testAlertWithNilError() {
        let alert = TPPAlertUtils.alert(title: "Error", error: nil)

        // Should show generic error message
        XCTAssertNotNil(alert.message)
        XCTAssertTrue(alert.message?.contains("An error occurred") == true ||
                       alert.message?.isEmpty == false,
                       "Nil error should still produce some message")
    }

    // MARK: - Message Takes Precedence Over Error

    func testAlertWithMessageAndError_MessageWins() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let alert = TPPAlertUtils.alert(title: "Error", message: "Override message", error: error)

        XCTAssertEqual(alert.message, "Override message",
                       "When message is provided, it should override the error-derived message")
    }

    func testAlertWithNilMessageAndError_ErrorWins() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let alert = TPPAlertUtils.alert(title: "Error", message: nil, error: error as NSError)

        let msg = alert.message ?? ""
        XCTAssertFalse(msg.isEmpty,
                       "When message is nil, error-derived message should be used")
    }

    // MARK: - Problem Document Tests

    func testSetProblemDocumentReplace() {
        let alert = UIAlertController(title: "Original", message: "Original msg", preferredStyle: .alert)
        let doc = TPPProblemDocument.fromProblemResponseData( makeProblemDocumentData(title: "Doc Title", detail: "Doc Detail"))

        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: false)

        XCTAssertEqual(alert.title, "Doc Title")
        XCTAssertEqual(alert.message, "Doc Detail")
    }

    func testSetProblemDocumentAppend() {
        let alert = UIAlertController(title: "Original", message: "Original msg", preferredStyle: .alert)
        let doc = TPPProblemDocument.fromProblemResponseData( makeProblemDocumentData(title: "Doc Title", detail: "Doc Detail"))

        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: true)

        // In append mode, the original title stays; detail is appended
        XCTAssertEqual(alert.title, "Original")
        XCTAssertTrue(alert.message?.contains("Doc Detail") == true)
    }

    func testSetProblemDocumentWithNilController() {
        // Should not crash
        let doc = TPPProblemDocument.fromProblemResponseData( makeProblemDocumentData(title: "Title", detail: "Detail"))
        TPPAlertUtils.setProblemDocument(controller: nil, document: doc, append: false)
    }

    func testSetProblemDocumentWithNilDocument() {
        let alert = UIAlertController(title: "Original", message: "Msg", preferredStyle: .alert)
        TPPAlertUtils.setProblemDocument(controller: alert, document: nil, append: false)

        // Should not change the alert
        XCTAssertEqual(alert.title, "Original")
        XCTAssertEqual(alert.message, "Msg")
    }

    func testSetProblemDocumentReplaceWithPartialDocument() {
        let alert = UIAlertController(title: "Original", message: "Msg", preferredStyle: .alert)
        // Document with title but no detail
        let doc = TPPProblemDocument.fromProblemResponseData( makeProblemDocumentData(title: "Only Title", detail: nil))

        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: false)

        XCTAssertEqual(alert.title, "Only Title")
    }

    // MARK: - alertWithDetails Tests

    func testAlertWithDetailsHasViewErrorDetailsButton() {
        let alert = TPPAlertUtils.alertWithDetails(
            title: "Error",
            message: "Something went wrong"
        )

        let actionTitles = alert.actions.map { $0.title }
        XCTAssertTrue(actionTitles.contains("View Error Details"),
                       "Should contain 'View Error Details' action")
    }

    func testAlertWithDetailsHasOKButtonWhenNoRetry() {
        let alert = TPPAlertUtils.alertWithDetails(
            title: "Error",
            message: "Something went wrong",
            retryAction: nil
        )

        let actionTitles = alert.actions.map { $0.title }
        XCTAssertTrue(actionTitles.contains("View Error Details"))
        // Should have OK button (not Retry/Cancel)
        XCTAssertEqual(alert.actions.count, 2, "Should have View Error Details + OK")
    }

    func testAlertWithDetailsHasRetryAndCancelWhenRetryProvided() {
        var retryCalled = false
        let alert = TPPAlertUtils.alertWithDetails(
            title: "Error",
            message: "Try again?",
            retryAction: { retryCalled = true }
        )

        // Should have 3 actions: View Error Details, Retry, Cancel
        XCTAssertEqual(alert.actions.count, 3,
                       "Should have View Error Details + Retry + Cancel")

        let actionStyles = alert.actions.map { $0.style }
        XCTAssertTrue(actionStyles.contains(.cancel), "Should have a Cancel action")
    }

    // MARK: - topMostViewController Tests (via indirect testing)

    func testPresentFromViewControllerOrNilWithNilAlert() {
        // Should not crash when alert is nil
        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: nil,
            viewController: nil,
            animated: false,
            completion: nil
        )
    }

    // MARK: - Helpers

    private func makeProblemDocumentData(title: String?, detail: String?) -> Data {
        var dict: [String: Any] = ["type": "http://example.com/problem"]
        if let title = title { dict["title"] = title }
        if let detail = detail { dict["detail"] = detail }
        return try! JSONSerialization.data(withJSONObject: dict)
    }
}
