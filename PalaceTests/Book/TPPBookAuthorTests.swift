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

    // MARK: - Equality / Property Matching Tests

    func test_sameNameAndURL_haveMatchingProperties() {
        let url = URL(string: "https://example.com/a")!
        let a = TPPBookAuthor(authorName: "Author", relatedBooksURL: url)
        let b = TPPBookAuthor(authorName: "Author", relatedBooksURL: url)
        XCTAssertEqual(a.name, b.name)
        XCTAssertEqual(a.relatedBooksURL, b.relatedBooksURL)
    }

    func test_differentName_haveDifferentProperties() {
        let a = TPPBookAuthor(authorName: "Alice", relatedBooksURL: nil)
        let b = TPPBookAuthor(authorName: "Bob", relatedBooksURL: nil)
        XCTAssertNotEqual(a.name, b.name)
    }
}
