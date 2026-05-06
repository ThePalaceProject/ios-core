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

        // Missing UpdatedKey: production relaxed to use .distantPast rather than
        // dropping the book (TPPBook.swift:282) — older catalog feeds occasionally
        // omit this. Verify the book is still constructed with a sentinel updated.
        let bookNoUpdatedDate = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "id": "666",
            "title": "The Lord of the Rings"
        ])
        XCTAssertNotNil(bookNoUpdatedDate, "Missing 'updated' must not drop the book — defaults to .distantPast")
        XCTAssertEqual(bookNoUpdatedDate?.updated, .distantPast)

        // Missing TitleKey: production drops the book (TPPBook.swift:225). A book
        // with no title is unrenderable, so this stricter guard remains.
        let bookNoTitle = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "id": "666",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNil(bookNoTitle)

        // Missing IdentifierKey: production drops the book (TPPBook.swift:221).
        let bookNoId = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "categories": ["Fantasy"],
            "title": "The Lord of the Rings",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNil(bookNoId)

        // Missing CategoriesKey: production relaxed to default to [] rather than
        // dropping (TPPBook.swift:230) — categories are optional metadata.
        let bookNoCategories = TPPBook(dictionary: [
            "acquisitions": acquisitions,
            "id": "666",
            "title": "The Lord of the Rings",
            "updated": "2020-09-08T09:22:45Z"
        ])
        XCTAssertNotNil(bookNoCategories, "Missing 'categories' must not drop the book — defaults to []")
        XCTAssertEqual(bookNoCategories?.categoryStrings, [])

        /*
         Note that we do not test the absence of acquisitions. The current code
         for the dictionary initializer *allows* object creation for a dictionary
         with no acquisitions. However this is not something we must necessarily
         ensure because
         (1) the TPPBook(entry:) initializer does NOT allow it,
         (2) a book with no acquisitions is a book the user won't be able to read,
         so useful only to look at the metadata
         */
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
