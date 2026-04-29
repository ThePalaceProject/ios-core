//
//  TPPUserFriendlyErrorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class TPPUserFriendlyErrorTests: XCTestCase {

    // MARK: - Protocol Default Implementation

    func testDefaultImplementation_titleIsNil() {
        struct TestError: TPPUserFriendlyError {}
        let error = TestError()
        XCTAssertNil(error.userFriendlyTitle)
        // Calling it twice must be idempotent (no side effects)
        XCTAssertNil(error.userFriendlyTitle,
                     "userFriendlyTitle must remain nil on repeated access")
    }

    func testDefaultImplementation_messageIsNil() {
        struct TestError: TPPUserFriendlyError {}
        let error = TestError()
        XCTAssertNil(error.userFriendlyMessage)
        // The title default must also be nil — both defaults must agree
        XCTAssertNil(error.userFriendlyTitle,
                     "Default protocol implementation must have both title and message nil")
    }

    // MARK: - NSError Extension - Problem Document

    func testNSError_withProblemDocument_hasFriendlyTitle() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Loan Limit Reached",
            "detail": "You have reached your checkout limit."
        ])

        let error = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "TestDomain",
            code: 403,
            userInfo: nil
        )

        XCTAssertEqual(error.userFriendlyTitle, "Loan Limit Reached")
    }

    func testNSError_withProblemDocument_hasFriendlyMessage() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Error",
            "detail": "You have reached your checkout limit."
        ])

        let error = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "TestDomain",
            code: 403,
            userInfo: nil
        )

        XCTAssertEqual(error.userFriendlyMessage, "You have reached your checkout limit.")
    }

    func testNSError_withoutProblemDocument_titleIsNil() {
        let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
        XCTAssertNil(error.userFriendlyTitle)
        // Without a problem document there is also no structured message
        XCTAssertNil(error.problemDocument,
                     "NSError without a problem document must have nil problemDocument")
    }

    func testNSError_withoutProblemDocument_messageIsLocalizedDescription() {
        let error = NSError(
            domain: "TestDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
        )

        XCTAssertEqual(error.userFriendlyMessage, "Something went wrong")
    }

    func testNSError_withoutProblemDocument_noUserInfo_messageIsNil() {
        let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
        XCTAssertNil(error.userFriendlyMessage)
        // The standard localizedDescription must still be accessible (provided by NSError)
        XCTAssertFalse(error.localizedDescription.isEmpty,
                       "NSError must always provide a non-empty localizedDescription")
        // But userFriendlyMessage (which requires localizedDescription from userInfo) is nil
        XCTAssertNil(error.userFriendlyTitle,
                     "No userInfo means both userFriendlyMessage and userFriendlyTitle are nil")
    }

    // MARK: - makeFromProblemDocument

    func testMakeFromProblemDocument_setsDomainAndCode() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Test",
            "detail": "Test detail"
        ])

        let error = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "com.palace.test",
            code: 500,
            userInfo: nil
        )

        XCTAssertEqual(error.domain, "com.palace.test")
        XCTAssertEqual(error.code, 500)
    }

    func testMakeFromProblemDocument_preservesExistingUserInfo() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Test",
            "detail": "Test detail"
        ])

        let error = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "TestDomain",
            code: 1,
            userInfo: ["customKey": "customValue"]
        )

        XCTAssertEqual(error.userInfo["customKey"] as? String, "customValue")
        XCTAssertNotNil(error.problemDocument, "Should also contain the problem document")
    }

    func testMakeFromProblemDocument_storesProblemDocument() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Stored Document",
            "status": 403,
            "detail": "Stored detail"
        ])

        let error = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "TestDomain",
            code: 403,
            userInfo: nil
        )

        XCTAssertNotNil(error.problemDocument)
        XCTAssertEqual(error.problemDocument?.title, "Stored Document")
    }

    // MARK: - Problem Document Access

    func testProblemDocument_accessor_returnsStoredDocument() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "type": "http://example.com/error",
            "title": "Access Test",
            "detail": "Testing accessor"
        ])

        let error = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "TestDomain",
            code: 1,
            userInfo: nil
        )

        XCTAssertNotNil(error.problemDocument)
        XCTAssertEqual(error.problemDocument?.title, "Access Test")
    }
}
