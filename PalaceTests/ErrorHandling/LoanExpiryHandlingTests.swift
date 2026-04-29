//
//  LoanExpiryHandlingTests.swift
//  PalaceTests
//
//  Tests for expired loan error detection and messaging.
//  Covers the `loan_term_limit_reached` silent-success path in the revoke flow
//  and the `Strings.ExpiredLoan` copy contract.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - TPPProblemDocument Loan Expiry Constant

final class ProblemDocumentLoanExpiryTests: XCTestCase {

    /// The constant must be the exact substring that Feedbooks embeds in the 500 detail field.
    /// Changing this value would break silent-cleanup detection in MyBooksDownloadCenter.
    func testDetailLoanTermLimitReached_hasExpectedValue() {
        XCTAssertEqual(TPPProblemDocument.DetailLoanTermLimitReached, "loan_term_limit_reached")
        XCTAssertFalse(TPPProblemDocument.DetailLoanTermLimitReached.isEmpty,
                       "DetailLoanTermLimitReached must be a non-empty string")
        // Must not match the TypeNoActiveLoan string (independent detection paths)
        XCTAssertFalse(TPPProblemDocument.TypeNoActiveLoan.contains(TPPProblemDocument.DetailLoanTermLimitReached),
                       "TypeNoActiveLoan and DetailLoanTermLimitReached must be independent strings")
    }

    /// A detail string matching the real Feedbooks/LCP server response is detected.
    func testDetailLoanTermLimitReached_detectedInRealServerDetail() {
        let serverDetail = "the license has expired | [\"loan_term_limit_reached\"]"
        XCTAssertTrue(serverDetail.contains(TPPProblemDocument.DetailLoanTermLimitReached))
        // Substring match must work with the exact substring
        XCTAssertTrue(serverDetail.contains("loan_term_limit_reached"),
                      "Server detail must contain the literal loan_term_limit_reached token")
    }

    /// A detail string with different content is not falsely detected.
    func testDetailLoanTermLimitReached_notDetectedInUnrelatedDetail() {
        let unrelated = "no-active-loan"
        XCTAssertFalse(unrelated.contains(TPPProblemDocument.DetailLoanTermLimitReached))
        // Must also not match an empty string
        XCTAssertFalse("".contains(TPPProblemDocument.DetailLoanTermLimitReached),
                       "Empty string must not contain DetailLoanTermLimitReached")
    }

    /// The error dict pattern used in MyBooksDownloadCenter correctly matches
    /// a simulated Feedbooks 500 response.
    func testLoanTermLimitReached_detectedFromErrorDictionary() {
        let errorDict: [String: Any] = [
            "type": "error",
            "title": "Error returning loan",
            "status": 500,
            "detail": "the license has expired | [\"loan_term_limit_reached\"]"
        ]
        let detail = errorDict["detail"] as? String
        let isExpired = detail?.contains(TPPProblemDocument.DetailLoanTermLimitReached) == true
        XCTAssertTrue(isExpired, "loan_term_limit_reached in detail should trigger silent cleanup")
    }

    /// A TypeNoActiveLoan error dict — already handled — should not accidentally match
    /// loan_term_limit_reached detection (both are independent paths).
    func testNoActiveLoan_doesNotMatchTermLimitCheck() {
        let errorDict: [String: Any] = [
            "type": TPPProblemDocument.TypeNoActiveLoan,
            "title": "No active loan",
            "status": 404,
            "detail": "no active loan found for this patron"
        ]
        let detail = errorDict["detail"] as? String
        let isTermLimit = detail?.contains(TPPProblemDocument.DetailLoanTermLimitReached) == true
        XCTAssertFalse(isTermLimit)
        // It should still be caught by the TypeNoActiveLoan branch, not this one.
        let isNoActiveLoan = (errorDict["type"] as? String) == TPPProblemDocument.TypeNoActiveLoan
        XCTAssertTrue(isNoActiveLoan)
    }
}

// MARK: - Expired Loan Strings

final class ExpiredLoanStringsTests: XCTestCase {

    func testExpiredLoanTitle_isNonEmpty() {
        XCTAssertFalse(Strings.ExpiredLoan.title.isEmpty)
        // Title must not be a raw key (i.e. actual localized text was loaded)
        XCTAssertFalse(Strings.ExpiredLoan.title.hasPrefix("ExpiredLoan"),
                       "Title must not fall back to the localization key itself")
    }

    func testExpiredLoanMessage_isNonEmpty() {
        XCTAssertFalse(Strings.ExpiredLoan.message.isEmpty)
        // Message should be distinct from the title
        XCTAssertNotEqual(Strings.ExpiredLoan.message, Strings.ExpiredLoan.title,
                          "message and title must be different strings")
    }

    func testExpiredLoanMessageWithDate_containsFormatSpecifier() {
        XCTAssertTrue(Strings.ExpiredLoan.messageWithDate.contains("%@"),
                      "messageWithDate must contain a %@ format specifier for the end date")
        // Only one date placeholder is expected
        let placeholders = Strings.ExpiredLoan.messageWithDate
            .components(separatedBy: "%@").count - 1
        XCTAssertEqual(placeholders, 1,
                       "messageWithDate should have exactly one %@ placeholder, found \(placeholders)")
    }

    func testExpiredLoanMessageWithDate_formatsDateCorrectly() {
        let knownDate = Date(timeIntervalSince1970: 0) // Jan 1, 1970
        let formatted = String(format: Strings.ExpiredLoan.messageWithDate, "January 1, 1970")
        XCTAssertTrue(formatted.contains("January 1, 1970"))
        XCTAssertFalse(formatted.contains("%@"), "Format specifier should be replaced after formatting")
    }

    /// The message copy should tell the user the book has been removed,
    /// so they are not left wondering where it went.
    func testExpiredLoanMessage_mentionsRemoval() {
        let message = Strings.ExpiredLoan.message.lowercased()
        XCTAssertTrue(message.contains("removed"), "Expired loan message should tell the user the book was removed")
        // Message must also be distinct from the title (different UX copy)
        XCTAssertNotEqual(Strings.ExpiredLoan.message.lowercased(), Strings.ExpiredLoan.title.lowercased(),
                          "message and title must contain different text")
    }
}
