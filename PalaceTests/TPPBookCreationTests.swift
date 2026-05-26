//
//  TPPBookCreationTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/27/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
import PalaceCatalog
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

    // MARK: - PP-4046: Audience + Language

    func testBookCreation_FromEntry_PopulatesAudienceAndLanguage() {
        // The NYPLOPDSAcquisitionPathEntry fixture has:
        //   <dcterms:language>en</dcterms:language>
        //   <category term="Adult" scheme="http://schema.org/audience" label="Adult"/>
        let book = TPPBook(entry: opdsEntry)
        XCTAssertEqual(book?.audience, "Adult",
                       "Audience must be lifted out of the schema.org/audience category")
        XCTAssertEqual(book?.language, "en")
    }

    func testBookCreation_RoundTripsAudienceAndLanguageThroughDictionary() {
        let original = TPPBook(entry: opdsEntry)!
        let revived = TPPBook(dictionary: original.dictionaryRepresentation())
        XCTAssertEqual(revived?.audience, "Adult",
                       "audience must survive disk persistence in the registry")
        XCTAssertEqual(revived?.language, "en",
                       "language must survive disk persistence in the registry")
    }

    func testBookCreation_FromEntry_AudienceAbsent() {
        // The minimal entry fixture has no audience category nor language.
        let book = TPPBook(entry: opdsEntryMinimal)
        XCTAssertNil(book?.audience,
                     "audience must be nil when no schema.org/audience category is present")
        XCTAssertNil(book?.language,
                     "language must be nil when no <language> element is present")
    }

    func testMergingPreservingMetadata_PrefersFreshThenSelf() {
        let acquisitions = [TPPFake.genericAcquisition]
        let stale = TPPBook(
            acquisitions: acquisitions, authors: nil, categoryStrings: nil,
            distributor: nil, identifier: "id-1", imageURL: nil, imageThumbnailURL: nil,
            published: nil, publisher: nil, subtitle: nil, summary: nil,
            title: "T", updated: Date(), annotationsURL: nil, analyticsURL: nil,
            alternateURL: nil, relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: nil,
            bookDuration: nil, audience: "Adult", language: "en",
            imageCache: MockImageCache()
        )
        let freshWithEmptyMetadata = TPPBook(
            acquisitions: acquisitions, authors: nil, categoryStrings: nil,
            distributor: nil, identifier: "id-1", imageURL: nil, imageThumbnailURL: nil,
            published: nil, publisher: nil, subtitle: nil, summary: nil,
            title: "T", updated: Date(), annotationsURL: nil, analyticsURL: nil,
            alternateURL: nil, relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: nil,
            bookDuration: nil, audience: nil, language: nil,
            imageCache: MockImageCache()
        )
        let merged = stale.mergingPreservingMetadata(from: freshWithEmptyMetadata)
        XCTAssertEqual(merged.audience, "Adult",
                       "Lean loans-feed entry must not wipe stored audience")
        XCTAssertEqual(merged.language, "en",
                       "Lean loans-feed entry must not wipe stored language")
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
                           audience: nil,
                           language: nil,
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
