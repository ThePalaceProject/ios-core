//
//  BorrowErrorMessageTests.swift
//  PalaceTests
//
//  Regression tests for borrow error message presentation.
//
//  These tests guard against a regression where our OPDS refactoring caused
//  technical error strings (e.g. "Invalid OPDS feed") to be shown to users
//  instead of the user-friendly "Borrowing [title] could not be completed."
//  message. The underlying transient failures from Demarques/Marketplace
//  servers are unchanged, but the alarming technical wording drove extra
//  support tickets.
//
//  The fix (and these tests) ensure that:
//  1. Users always see the friendly base message ("Borrowing X could not be completed.")
//  2. Problem document details from the server are appended when available
//  3. Recovery suggestions are appended when no problem document exists
//  4. Technical PalaceError descriptions never appear as the primary message
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BorrowErrorMessageTests: XCTestCase {

    // MARK: - Constants

    private let bookTitle = "The Great Adventure"

    /// The expected user-friendly base message
    private var expectedBaseMessage: String {
        String(format: Strings.MyDownloadCenter.borrowFailedMessage, bookTitle)
    }

    /// Technical strings that should NEVER appear as the primary user-facing message.
    /// These are PalaceError.localizedDescription values for errors that can occur during borrow.
    private let technicalErrorStrings = [
        "Invalid OPDS feed",
        "Invalid JSON data",
        "Invalid XML data",
        "Missing required data field",
        "Data format is invalid",
        "Text encoding error",
        "Server returned an error",
        "Request timed out",
        "No internet connection",
        "Network connection was lost",
    ]

    // MARK: - Base Message Tests

    /// Regression test: The message MUST start with the user-friendly base message
    /// for transient OPDS feed errors (the most common case from Demarques servers).
    func testOPDSFeedInvalid_showsUserFriendlyMessage_notTechnicalError() {
        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: nil
        )

        XCTAssertTrue(
            message.hasPrefix(expectedBaseMessage),
            "Message should start with '\(expectedBaseMessage)' but was: '\(message)'"
        )
        XCTAssertFalse(
            message.contains("Invalid OPDS feed"),
            "Technical string 'Invalid OPDS feed' must not appear in user-facing message"
        )
    }

    /// Verifies the base message is always present regardless of error type
    func testAllRetryableParsingErrors_showUserFriendlyBaseMessage() {
        let parsingErrors: [PalaceError] = [
            .parsing(.opdsFeedInvalid),
            .parsing(.invalidJSON),
            .parsing(.invalidXML),
            .parsing(.missingRequiredField),
            .parsing(.invalidFormat),
            .parsing(.encodingError),
        ]

        for error in parsingErrors {
            let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
                for: bookTitle,
                error: error,
                problemDocument: nil
            )

            XCTAssertTrue(
                message.hasPrefix(expectedBaseMessage),
                "\(error): message should start with friendly base, but was: '\(message)'"
            )
        }
    }

    func testNetworkErrors_showUserFriendlyBaseMessage() {
        let networkErrors: [PalaceError] = [
            .network(.serverError),
            .network(.timeout),
            .network(.noConnection),
            .network(.unknown),
            .network(.invalidResponse),
        ]

        for error in networkErrors {
            let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
                for: bookTitle,
                error: error,
                problemDocument: nil
            )

            XCTAssertTrue(
                message.hasPrefix(expectedBaseMessage),
                "\(error): message should start with friendly base, but was: '\(message)'"
            )
        }
    }

    // MARK: - Technical String Exclusion

    /// The core regression test: no PalaceError technical description should appear
    /// as the primary (first line) message shown to users.
    func testNoTechnicalErrorString_appearsAsMessage() {
        let borrowErrors: [PalaceError] = [
            .parsing(.opdsFeedInvalid),
            .parsing(.invalidJSON),
            .parsing(.invalidXML),
            .parsing(.missingRequiredField),
            .parsing(.invalidFormat),
            .parsing(.encodingError),
            .network(.serverError),
            .network(.timeout),
            .network(.noConnection),
            .network(.unknown),
            .network(.invalidResponse),
            .download(.networkFailure),
            .bookRegistry(.invalidState),
            .bookRegistry(.syncFailed),
        ]

        for error in borrowErrors {
            let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
                for: bookTitle,
                error: error,
                problemDocument: nil
            )

            // The message must never START with a technical error string
            for technical in technicalErrorStrings {
                XCTAssertFalse(
                    message.hasPrefix(technical),
                    "\(error): message must not start with technical string '\(technical)'. Got: '\(message)'"
                )
            }
        }
    }

    // MARK: - Problem Document Tests

    func testWithProblemDocument_appendsServerDetail() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": "The loan limit for this library has been reached."
        ])

        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: problemDoc
        )

        XCTAssertTrue(
            message.hasPrefix(expectedBaseMessage),
            "Should start with friendly base message even with problem document"
        )
        XCTAssertTrue(
            message.contains("The loan limit for this library has been reached."),
            "Should include problem document detail"
        )
    }

    func testWithProblemDocument_emptyDetail_fallsBackToBaseMessage() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": ""
        ])

        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: problemDoc
        )

        XCTAssertTrue(
            message.hasPrefix(expectedBaseMessage),
            "Should use base message when problem document detail is empty"
        )
    }

    func testWithProblemDocument_nilDetail_fallsBackToBaseMessage() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "type": "http://librarysimplified.org/terms/problem/unknown"
        ])

        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .network(.serverError),
            problemDocument: problemDoc
        )

        XCTAssertTrue(
            message.hasPrefix(expectedBaseMessage),
            "Should use base message when problem document has no detail"
        )
    }

    func testNilProblemDocument_usesRecoverySuggestion() {
        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: nil
        )

        // opdsFeedInvalid has a non-nil recoverySuggestion
        let recovery = ParsingError.opdsFeedInvalid.recoverySuggestion
        if let recovery = recovery {
            XCTAssertTrue(
                message.contains(recovery),
                "Should include recovery suggestion when no problem document"
            )
        }
    }

    // MARK: - Problem Document Priority

    /// When both a problem document detail and recovery suggestion exist,
    /// the problem document detail should take priority (server knows best).
    func testProblemDocument_takesPriorityOverRecoverySuggestion() {
        let serverMessage = "This title is temporarily unavailable. Please try again in a few minutes."
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": serverMessage
        ])

        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: problemDoc
        )

        XCTAssertTrue(message.contains(serverMessage))

        // Recovery suggestion should NOT also be appended
        let recovery = ParsingError.opdsFeedInvalid.recoverySuggestion ?? ""
        if !recovery.isEmpty {
            XCTAssertFalse(
                message.contains(recovery),
                "Recovery suggestion should not appear when problem document detail is present"
            )
        }
    }

    // MARK: - Book Title Formatting

    func testBookTitle_isIncludedInMessage() {
        let title = "A Very Long Book Title With Special Characters: Vol. 2"
        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: title,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: nil
        )

        XCTAssertTrue(
            message.contains(title),
            "Book title should appear in the error message"
        )
    }

    func testDifferentBookTitles_produceDistinctMessages() {
        let message1 = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: "Book Alpha",
            error: .parsing(.opdsFeedInvalid),
            problemDocument: nil
        )
        let message2 = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: "Book Beta",
            error: .parsing(.opdsFeedInvalid),
            problemDocument: nil
        )

        XCTAssertNotEqual(message1, message2, "Different book titles should produce different messages")
        XCTAssertTrue(message1.contains("Book Alpha"))
        XCTAssertTrue(message2.contains("Book Beta"))
    }

    // MARK: - Consistency with Legacy Behavior

    /// The new async path message should match the pattern from the legacy
    /// `showAlert(for:with:alertTitle:)` method in MyBooksDownloadCenter.swift.
    func testMessageFormat_matchesLegacyPattern_noProblemDoc() {
        let legacyMessage = String(format: "Borrowing %@ could not be completed.", bookTitle)

        let newMessage = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: nil
        )

        XCTAssertTrue(
            newMessage.hasPrefix(legacyMessage),
            "New message should start with same base as legacy: '\(legacyMessage)'"
        )
    }

    func testMessageFormat_matchesLegacyPattern_withProblemDoc() {
        let serverDetail = "An internal error occurred"
        let problemDoc = TPPProblemDocument.fromDictionary(["detail": serverDetail])

        let legacyMessage = String(format: "Borrowing %@ could not be completed.", bookTitle) + "\n\n" + serverDetail

        let newMessage = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: bookTitle,
            error: .parsing(.opdsFeedInvalid),
            problemDocument: problemDoc
        )

        XCTAssertEqual(
            newMessage, legacyMessage,
            "New message with problem doc should match legacy format exactly"
        )
    }
}
