//
//  TPPBookBearerTokenTests.swift
//  PalaceTests
//
//  Tests for TPPBook+Extensions bearer token keychain persistence:
//  - bearerToken read/write
//  - bearerTokenFulfillURL read/write/clearing
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookBearerTokenTests: XCTestCase {

    private var book: TPPBook!
    private var fulfillURLKey: String!
    private var tokenKey: String!

    override func setUp() {
        super.setUp()
        book = TPPBookMocker.mockBook(distributorType: .BearerToken)
        fulfillURLKey = "\(book.identifier)-fulfillURL"
        tokenKey = book.identifier
    }

    override func tearDown() {
        TPPKeychain.shared()?.removeObject(forKey: fulfillURLKey)
        TPPKeychain.shared()?.removeObject(forKey: tokenKey)
        book = nil
        super.tearDown()
    }

    // MARK: - bearerToken

    func testBearerToken_defaultsToNil() {
        XCTAssertNil(book.bearerToken)
    }

    func testBearerToken_writeAndRead() {
        book.bearerToken = "test-access-token-123"

        XCTAssertEqual(book.bearerToken, "test-access-token-123")
    }

    func testBearerToken_clearWithNil() {
        book.bearerToken = "token-to-clear"
        XCTAssertNotNil(book.bearerToken)

        book.bearerToken = nil
        XCTAssertNil(book.bearerToken)
    }

    // MARK: - bearerTokenFulfillURL

    func testFulfillURL_defaultsToNil() {
        XCTAssertNil(book.bearerTokenFulfillURL)
    }

    func testFulfillURL_writeAndRead() {
        let url = URL(string: "https://cm.example.com/fulfill/book-123")!
        book.bearerTokenFulfillURL = url

        XCTAssertEqual(book.bearerTokenFulfillURL, url)
    }

    func testFulfillURL_clearWithNil() {
        book.bearerTokenFulfillURL = URL(string: "https://cm.example.com/fulfill/abc")!
        XCTAssertNotNil(book.bearerTokenFulfillURL)

        book.bearerTokenFulfillURL = nil
        XCTAssertNil(book.bearerTokenFulfillURL)
    }

    func testFulfillURL_overwrite() {
        let url1 = URL(string: "https://cm.example.com/fulfill/first")!
        let url2 = URL(string: "https://cm.example.com/fulfill/second")!

        book.bearerTokenFulfillURL = url1
        XCTAssertEqual(book.bearerTokenFulfillURL, url1)

        book.bearerTokenFulfillURL = url2
        XCTAssertEqual(book.bearerTokenFulfillURL, url2)
    }

    func testFulfillURL_independentPerBook() {
        let book2 = TPPBookMocker.mockBook(distributorType: .BearerToken)
        let key2 = "\(book2.identifier)-fulfillURL"

        let url1 = URL(string: "https://cm.example.com/fulfill/book1")!
        let url2 = URL(string: "https://cm.example.com/fulfill/book2")!

        book.bearerTokenFulfillURL = url1
        book2.bearerTokenFulfillURL = url2

        XCTAssertEqual(book.bearerTokenFulfillURL, url1)
        XCTAssertEqual(book2.bearerTokenFulfillURL, url2)

        TPPKeychain.shared()?.removeObject(forKey: key2)
    }

    func testFulfillURL_persistsAcrossNewBookInstances() {
        let url = URL(string: "https://cm.example.com/fulfill/persist-test")!
        book.bearerTokenFulfillURL = url

        let sameBook = TPPBookMocker.mockBook(
            identifier: book.identifier,
            title: "Same Book",
            distributorType: .BearerToken
        )

        XCTAssertEqual(
            sameBook.bearerTokenFulfillURL, url,
            "Fulfill URL should persist across new TPPBook instances with the same identifier"
        )
    }
}
