//
//  TPPBookCreationTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/27/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

class TPPBookCreationTests: XCTestCase {
    var opdsEntry: TPPOPDSEntry!
    var opdsEntryMinimal: TPPOPDSEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.opdsEntry = TPPFake.opdsEntry
        self.opdsEntryMinimal = TPPFake.opdsEntryMinimal
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        self.opdsEntry = nil
        self.opdsEntryMinimal = nil
    }

    func testBookCreationViaDictionary() throws {
        let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]

        let book = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "id": "666",
            "title": "The Lord of the Rings",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertEqual(book?.identifier, "666",
                       "Dictionary init must preserve 'id' as book identifier")
        XCTAssertEqual(book?.title, "The Lord of the Rings",
                       "Dictionary init must preserve 'title'")
        XCTAssertEqual(book?.categoryStrings, ["Fantasy"],
                       "Dictionary init must preserve 'categories'")
        XCTAssertFalse(book?.acquisitions.isEmpty ?? true,
                       "Dictionary init must preserve 'acquisitions'")
        XCTAssertNoThrow(book?.loggableShortString())
        XCTAssertNoThrow(book?.loggableDictionary())

        // Hard requirements: id + title must be present. Everything else has
        // a sensible default so the registry does not drop downloaded books
        // when a single field goes missing on disk. See TPPBook.init(dictionary:).

        let bookNoTitle = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "id": "666",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNil(bookNoTitle, "missing title is a hard failure")

        let bookEmptyTitle = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "id": "666",
            "title": "",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNil(bookEmptyTitle, "empty title is a hard failure")

        let bookNoId = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "title": "The Lord of the Rings",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNil(bookNoId, "missing id is a hard failure")

        // Optional fields: missing "updated" or "categories" must be salvaged,
        // not dropped. The dictionary init is forgiving by design so registry
        // drift on a single optional field does not wipe a downloaded book.
        let bookNoUpdatedDate = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "id": "666",
            "title": "The Lord of the Rings"
        ])
        XCTAssertNotNil(bookNoUpdatedDate, "missing 'updated' must not drop the book")
        XCTAssertEqual(bookNoUpdatedDate?.identifier, "666")

        let bookNoCategories = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "id": "666",
            "title": "The Lord of the Rings",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNotNil(bookNoCategories, "missing 'categories' must not drop the book")
        XCTAssertEqual(bookNoCategories?.categoryStrings, [], "missing categories defaults to empty")

        // Acquisitions are also optional by design — a metadata-only book
        // (no playable/readable link) still carries useful information.
        let bookNoAcquisitions = TPPBook(dictionary: [
            "categories": ["Fantasy"],
            "id": "666",
            "title": "The Lord of the Rings",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNotNil(bookNoAcquisitions, "missing 'acquisitions' must not drop the book")
        XCTAssertTrue(bookNoAcquisitions?.acquisitions.isEmpty ?? false)
    }

    func testBookCreationViaFactoryMethod() {
        let book = TPPBook(entry: opdsEntryMinimal)
        // categoryStrings should be an empty array (not nil) even when entry has no categories
        XCTAssertEqual(book?.categoryStrings, [],
                       "Factory init with no-category entry must default to empty array, not nil")
        XCTAssertFalse(book?.identifier.isEmpty ?? true,
                       "Factory init must populate identifier from entry")
        XCTAssertFalse(book?.title.isEmpty ?? true,
                       "Factory init must populate title from entry")
    }

    // for completeness only. This test is not strictly necessary because the
    // member-wise initializer is not public
    func testBookCreationViaMemberWiseInitializer() {
        let book = TPPBook(acquisitions: opdsEntry.acquisitions,
                           authors: nil,
                           categoryStrings: ["Test String 1", "Test String 2"],
                           distributor: nil,
                           identifier: "666",
                           imageURL: nil,
                           imageThumbnailURL: nil,
                           published: nil,
                           publisher: nil,
                           subtitle: nil,
                           summary: nil,
                           title: "The Lord of the Rings",
                           updated: Date(),
                           annotationsURL: nil,
                           analyticsURL: nil,
                           alternateURL: nil,
                           relatedWorksURL: nil,
                           previewLink: nil,
                           seriesURL: nil,
                           revokeURL: nil,
                           reportURL: nil,
                           timeTrackingURL: nil,
                           contributors: nil,
                           bookDuration: nil,
                           imageCache: MockImageCache()
        )

        XCTAssertNotNil(book)
        XCTAssertNotNil(book.acquisitions)
        XCTAssertNotNil(book.categoryStrings)
        XCTAssertNotNil(book.identifier)
        XCTAssertNotNil(book.title)
        XCTAssertNotNil(book.updated)
    }
}
