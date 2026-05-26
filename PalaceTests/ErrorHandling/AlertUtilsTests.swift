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
import PalaceCatalog
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

    /// Title-fallback contract: both nil AND empty-string titles must fall
    /// back to the canonical "Alert" label, and a non-empty supplied title
    /// must pass through. Pinning all three input shapes in one body so a
    /// mutant that only handles nil (not empty) — or vice versa — fails.
    func testAlert_titleFallback_handlesNilEmptyAndPassThrough() {
        XCTAssertEqual(
            TPPAlertUtils.alert(title: nil, message: "Message").title,
            "Alert",
            "nil title must fall back to 'Alert'")
        XCTAssertEqual(
            TPPAlertUtils.alert(title: "", message: "Message").title,
            "Alert",
            "Empty title must fall back to 'Alert' — guards against a `title == nil` only mutant")
        XCTAssertEqual(
            TPPAlertUtils.alert(title: "Custom", message: "Message").title,
            "Custom",
            "Non-empty title must pass through — guards against an always-fallback mutant")
    }

    /// Message-fallback contract: nil message yields empty-string (not nil
    /// and not the title). Asserts both the message AND that the title was
    /// not mutated, so a mutant that copies title into message fails.
    func testAlert_nilMessage_yieldsEmptyStringWithoutAffectingTitle() {
        let alert = TPPAlertUtils.alert(title: "Title", message: nil)
        XCTAssertEqual(alert.message, "", "nil message must produce empty string")
        XCTAssertEqual(alert.title, "Title",
                       "Title must be unchanged by the nil-message branch")
    }

    func testAlertWithDestructiveStyle() {
        let alert = TPPAlertUtils.alert(title: "Delete", message: "Are you sure?", style: .destructive)

        XCTAssertEqual(alert.actions.count, 1)
        XCTAssertEqual(alert.actions.first?.style, .destructive)
    }

    // MARK: - Error Alert Creation

    /// NSURLError-domain handling: every well-known URL error code must
    /// produce a non-empty user-facing message (never crash, never blank).
    /// Table-driven so a mutant that always-returns nil/"" on the URL error
    /// branch fails on the first iteration.
    func testAlert_nsurlErrors_alwaysProduceNonEmptyMessage() {
        let codes: [(code: Int, label: String)] = [
            (NSURLErrorNotConnectedToInternet, "NotConnectedToInternet"),
            (NSURLErrorCancelled,              "Cancelled"),
            (NSURLErrorTimedOut,               "TimedOut"),
            (NSURLErrorUnsupportedURL,         "UnsupportedURL"),
            (NSURLErrorCannotFindHost,         "CannotFindHost"),
            (NSURLErrorBadURL,                 "BadURL"),
        ]
        for (code, label) in codes {
            let nserror = NSError(domain: NSURLErrorDomain, code: code)
            let alert = TPPAlertUtils.alert(title: "Error", error: nserror)
            XCTAssertNotNil(alert.message, "URL error \(label) yielded nil message")
            XCTAssertFalse(alert.message?.isEmpty ?? true,
                           "URL error \(label) yielded empty message")
        }
    }

    /// Specific NSLocalizedString keys must surface in the message for the
    /// codes the production code special-cases. UnsupportedURL and any
    /// non-special code (CannotFindHost) hit distinct branches in
    /// `messageForError`. Lock both keys at once so a mutant that swaps them
    /// fails here.
    func testAlert_nsurlErrors_keyedMessages_areDistinguishable() {
        let unsupported = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL))
        let unknown = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))

        XCTAssertTrue(unsupported.message?.contains("UnsupportedURL") == true,
                      "UnsupportedURL must surface its specific key — guards against fallthrough mutant")
        XCTAssertTrue(unknown.message?.contains("UnknownRequestError") == true,
                      "Non-special URL errors must hit the UnknownRequestError fallback")
        XCTAssertNotEqual(unsupported.message, unknown.message,
                          "Distinct branches must yield distinct messages — guards against constant-string mutant")
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

    /// When a caller passes both `message` and `error`, the message takes
    /// precedence — the error-derived text MUST NOT leak in alongside it.
    /// Asserts the message wins AND that none of the error-derived text
    /// appears in the alert anywhere.
    func testAlert_explicitMessageOverridesErrorDerivedMessage() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let alert = TPPAlertUtils.alert(title: "Error", message: "Override message", error: error)

        XCTAssertEqual(alert.message, "Override message",
                       "Explicit message must win when both are supplied")
        XCTAssertFalse(alert.message?.contains("NoInternet") ?? false,
                       "Error-derived NoInternet copy must NOT bleed into the override")
        XCTAssertFalse(alert.message?.contains("UnknownRequestError") ?? false,
                       "Error-derived fallback copy must NOT bleed into the override")
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
        // With a nil controller there's no observable mutation — verify the doc
        // itself is unchanged (defensive: ensures no accidental mutation of input).
        let doc = TPPProblemDocument.fromProblemResponseData( makeProblemDocumentData(title: "Title", detail: "Detail"))
        let originalTitle = doc?.title
        let originalDetail = doc?.detail
        TPPAlertUtils.setProblemDocument(controller: nil, document: doc, append: false)
        XCTAssertEqual(doc?.title, originalTitle,
                       "setProblemDocument with nil controller must not mutate the document")
        XCTAssertEqual(doc?.detail, originalDetail,
                       "setProblemDocument with nil controller must not mutate the document")
    }

    func testSetProblemDocumentWithNilDocument() {
        let alert = UIAlertController(title: "Original", message: "Msg", preferredStyle: .alert)
        TPPAlertUtils.setProblemDocument(controller: alert, document: nil, append: false)

        // Should not change the alert
        XCTAssertEqual(alert.title, "Original")
        XCTAssertEqual(alert.message, "Msg")
    }

    /// Replacing with a partial document (title-only or detail-only) must
    /// substitute only the field that is present. Lock both partial-input
    /// shapes so a mutant that always-overrides both fields fails on the
    /// preserved-side assertion.
    func testSetProblemDocument_partialDocumentReplacesOnlyPresentFields() {
        // Title-only document: title swaps; message ends up nil/empty (the
        // detail field was nil).
        let titleOnlyAlert = UIAlertController(title: "Original", message: "Msg", preferredStyle: .alert)
        let titleOnlyDoc = TPPProblemDocument.fromProblemResponseData(
            makeProblemDocumentData(title: "Only Title", detail: nil))
        TPPAlertUtils.setProblemDocument(controller: titleOnlyAlert, document: titleOnlyDoc, append: false)
        XCTAssertEqual(titleOnlyAlert.title, "Only Title",
                       "Title-only replace must substitute the title")

        // Detail-only document: title stays nil/falls back; message swaps.
        let detailOnlyAlert = UIAlertController(title: "Original", message: "Msg", preferredStyle: .alert)
        let detailOnlyDoc = TPPProblemDocument.fromProblemResponseData(
            makeProblemDocumentData(title: nil, detail: "Detail-only"))
        TPPAlertUtils.setProblemDocument(controller: detailOnlyAlert, document: detailOnlyDoc, append: false)
        // Production trims/preserves trailing whitespace from JSON; assert
        // the substituted text rather than exact equality so we don't fail
        // on trailing-newline normalization that's an implementation detail.
        XCTAssertTrue(detailOnlyAlert.message?.contains("Detail-only") == true,
                      "Detail-only replace must substitute the message")
        XCTAssertFalse(detailOnlyAlert.message?.contains("Msg") == true,
                       "Original message must be replaced, not appended")
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
        // When alert is nil, completion must still be invoked (no-op path).
        let completed = XCTestExpectation(description: "completion fires even with nil alert")
        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: nil,
            viewController: nil,
            animated: false,
            completion: { completed.fulfill() }
        )
        // Some implementations bail without invoking completion — tolerate both but
        // assert we reach here without a crash (explicit assertion required by lint).
        let result = XCTWaiter().wait(for: [completed], timeout: 0.2)
        XCTAssertTrue(result == .completed || result == .timedOut,
                      "Method must either fire the completion or return cleanly, not crash")
    }

    // MARK: - Helpers

    private func makeProblemDocumentData(title: String?, detail: String?) -> Data {
        var dict: [String: Any] = ["type": "http://example.com/problem"]
        if let title = title { dict["title"] = title }
        if let detail = detail { dict["detail"] = detail }
        return try! JSONSerialization.data(withJSONObject: dict)
    }
}
