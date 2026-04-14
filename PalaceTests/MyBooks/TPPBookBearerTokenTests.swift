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
import Security
@testable import Palace

final class TPPBookBearerTokenTests: XCTestCase {

    private var book: TPPBook!
    private var fulfillURLKey: String!
    private var tokenKey: String!

    /// Returns true if the keychain is accessible (fails in CI without code signing)
    private var isKeychainAccessible: Bool {
        let testKey = "TPPBookBearerTokenTests.keychainCheck"
        let testData = "test".data(using: .utf8)!

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: testKey,
            kSecValueData as String: testData
        ]

        SecItemDelete(addQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        SecItemDelete(addQuery as CFDictionary)

        return status == errSecSuccess
    }

    override func setUp() {
        super.setUp()
        book = TPPBookMocker.mockBook(distributorType: .BearerToken)
        fulfillURLKey = "\(book.identifier)-fulfillURL"
        tokenKey = book.identifier
    }

    override func tearDown() {
        TPPKeychain.shared.removeObject(forKey: fulfillURLKey)
        TPPKeychain.shared.removeObject(forKey: tokenKey)
        book = nil
        super.tearDown()
    }

    // MARK: - bearerToken

    func testBearerToken_defaultsToNil() {
        XCTAssertNil(book.bearerToken, "bearerToken must default to nil for a freshly created book")
        // A different book must also default to nil
        let book2 = TPPBookMocker.mockBook(distributorType: .BearerToken)
        XCTAssertNil(book2.bearerToken, "bearerToken must default to nil for every new book")
        // The book identifiers must be distinct to prove isolation
        XCTAssertNotEqual(book.identifier, book2.identifier, "Different mock books must have distinct identifiers")
    }

    func testBearerToken_writeAndRead() {
        book.bearerToken = "test-access-token-123"
        let firstRead = book.bearerToken
        XCTAssertEqual(firstRead, "test-access-token-123")
        // A different token value must overwrite the first
        book.bearerToken = "updated-token-456"
        let secondRead = book.bearerToken
        XCTAssertEqual(secondRead, "updated-token-456", "Overwriting bearerToken must store the new value")
        XCTAssertNotEqual(secondRead, firstRead, "Old token must no longer be returned after overwrite")
    }

    func testBearerToken_clearWithNil() {
        book.bearerToken = "token-to-clear"
        let beforeClear = book.bearerToken
        XCTAssertNotNil(beforeClear, "Token must be set before clearing")

        book.bearerToken = nil
        let afterClear = book.bearerToken
        XCTAssertNil(afterClear)
        XCTAssertNotEqual(afterClear, beforeClear, "Cleared token must differ from the previously stored token")
    }

    // MARK: - bearerTokenFulfillURL

    func testFulfillURL_defaultsToNil() {
        XCTAssertNil(book.bearerTokenFulfillURL, "bearerTokenFulfillURL must default to nil")
        // bearerToken must also default to nil (both are unset for a new book)
        XCTAssertNil(book.bearerToken, "bearerToken must also default to nil")
    }

    func testFulfillURL_writeAndRead() {
        let url = URL(string: "https://cm.example.com/fulfill/book-123")!
        book.bearerTokenFulfillURL = url
        let read = book.bearerTokenFulfillURL
        XCTAssertEqual(read, url)
        // URL path and host must be preserved verbatim
        XCTAssertEqual(read?.host, "cm.example.com", "Stored URL must preserve its host")
        XCTAssertEqual(read?.lastPathComponent, "book-123", "Stored URL must preserve its last path component")
    }

    func testFulfillURL_clearWithNil() {
        book.bearerTokenFulfillURL = URL(string: "https://cm.example.com/fulfill/abc")!
        let beforeClear = book.bearerTokenFulfillURL
        XCTAssertNotNil(beforeClear, "URL must be set before clearing")

        book.bearerTokenFulfillURL = nil
        let afterClear = book.bearerTokenFulfillURL
        XCTAssertNil(afterClear)
        XCTAssertNotEqual(afterClear, beforeClear, "Cleared URL must differ from the previously stored URL")
    }

    func testFulfillURL_overwrite() {
        let url1 = URL(string: "https://cm.example.com/fulfill/first")!
        let url2 = URL(string: "https://cm.example.com/fulfill/second")!

        book.bearerTokenFulfillURL = url1
        let after1 = book.bearerTokenFulfillURL
        XCTAssertEqual(after1, url1)

        book.bearerTokenFulfillURL = url2
        let after2 = book.bearerTokenFulfillURL
        XCTAssertEqual(after2, url2)
        XCTAssertNotEqual(after2, after1, "Overwriting fulfillURL must store the new value, not the old one")
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

        TPPKeychain.shared.removeObject(forKey: key2)
    }

    /// Tests that keychain data persists across different TPPBook instances with the same identifier.
    /// This simulates what happens when the app restarts and creates new book instances.
    /// Requires actual keychain access, which may not be available in CI without code signing.
    func testFulfillURL_persistsAcrossNewBookInstances() throws {
        try XCTSkipUnless(isKeychainAccessible, "Keychain not accessible (likely running in CI without code signing)")

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
