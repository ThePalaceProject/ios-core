//
//  TPPBookAuthorTests.swift
//  PalaceTests
//
//  Tests for TPPBookAuthor model.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookAuthorTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_WithNameAndURL_SetsProperties() {
        let url = URL(string: "https://example.com/authors/1")!
        let author = TPPBookAuthor(authorName: "Jane Austen", relatedBooksURL: url)

        XCTAssertEqual(author.name, "Jane Austen")
        XCTAssertEqual(author.relatedBooksURL, url)
    }

    func testInit_WithNilURL_SetsURLToNil() {
        let author = TPPBookAuthor(authorName: "Anonymous", relatedBooksURL: nil)

        XCTAssertEqual(author.name, "Anonymous")
        XCTAssertNil(author.relatedBooksURL)
    }

    func testInit_EmptyName_AllowsEmptyString() {
        let author = TPPBookAuthor(authorName: "", relatedBooksURL: nil)

        XCTAssertEqual(author.name, "")
    }

    // MARK: - NSObject Conformance

    func testIsKindOfClass_NSObject() {
        let author = TPPBookAuthor(authorName: "Test", relatedBooksURL: nil)

        XCTAssertTrue(author is NSObject)
    }
}
