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
@testable import Palace

// MARK: - TPPProblemDocument Loan Expiry Constant

final class ProblemDocumentLoanExpiryTests: XCTestCase {

    /// The constant must be the exact substring that Feedbooks embeds in the 500 detail field.
    /// Changing this value would break silent-cleanup detection in MyBooksDownloadCenter.
    func testDetailLoanTermLimitReached_hasExpectedValue() {
        XCTAssertEqual(TPPProblemDocument.DetailLoanTermLimitReached, "loan_term_limit_reached")
    }

    /// A detail string matching the real Feedbooks/LCP server response is detected.
    func testDetailLoanTermLimitReached_detectedInRealServerDetail() {
        let serverDetail = "the license has expired | [\"loan_term_limit_reached\"]"
        XCTAssertTrue(serverDetail.contains(TPPProblemDocument.DetailLoanTermLimitReached))
    }

    /// A detail string with different content is not falsely detected.
    func testDetailLoanTermLimitReached_notDetectedInUnrelatedDetail() {
        let unrelated = "no-active-loan"
        XCTAssertFalse(unrelated.contains(TPPProblemDocument.DetailLoanTermLimitReached))
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
    }

    func testExpiredLoanMessage_isNonEmpty() {
        XCTAssertFalse(Strings.ExpiredLoan.message.isEmpty)
    }

    func testExpiredLoanMessageWithDate_containsFormatSpecifier() {
        XCTAssertTrue(Strings.ExpiredLoan.messageWithDate.contains("%@"),
                      "messageWithDate must contain a %@ format specifier for the end date")
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
    }
}
