//
//  DownloadErrorInfoTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for DownloadErrorInfo struct — PP-3707
final class DownloadErrorInfoTests: XCTestCase {

    // MARK: - Convenience Initializer (non-retryable)

    func testConvenienceInit_setsFieldsCorrectly() {
        let info = DownloadErrorInfo(bookId: "book-123", title: "Error", message: "Something failed")
        XCTAssertEqual(info.bookId, "book-123")
        XCTAssertEqual(info.title, "Error")
        XCTAssertEqual(info.message, "Something failed")
        XCTAssertNil(info.retryAction)
    }

    // MARK: - Full Initializer (retryable)

    func testFullInit_withRetryAction() {
        var retried = false
        let info = DownloadErrorInfo(
            bookId: "book-456",
            title: "Download Failed",
            message: "Network error",
            retryAction: { retried = true }
        )

        XCTAssertEqual(info.bookId, "book-456")
        XCTAssertNotNil(info.retryAction)
        info.retryAction?()
        XCTAssertTrue(retried)
    }

    func testFullInit_withNilRetryAction() {
        let info = DownloadErrorInfo(
            bookId: "book-789",
            title: "Error",
            message: "Msg",
            retryAction: nil
        )
        XCTAssertNil(info.retryAction)
    }
}
