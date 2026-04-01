//
//  TPPBookTests.swift
//  PalaceTests
//
//  Comprehensive tests for TPPBook model: serialization round-trips,
//  computed properties, availability logic, metadata merging, and Comparable.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a TPPBook with sensible defaults. Override any parameter to customise.
    private func makeBook(
        identifier: String = "test-id",
        title: String = "Test Title",
        authors: [TPPBookAuthor]? = [TPPBookAuthor(authorName: "Author One",
                                                    relatedBooksURL: URL(string: "http://example.com/author1"))],
        categoryStrings: [String]? = ["Fiction", "Fantasy"],
        distributor: String? = "Test Distributor",
        acquisitions: [TPPOPDSAcquisition]? = nil,
        imageURL: URL? = nil,
        imageThumbnailURL: URL? = nil,
        published: Date? = Date(timeIntervalSince1970: 1_000_000),
        publisher: String? = "Test Publisher",
        subtitle: String? = "A Subtitle",
        summary: String? = "A summary of the book",
        updated: Date = Date(timeIntervalSince1970: 2_000_000),
        annotationsURL: URL? = URL(string: "http://example.com/annotations"),
        analyticsURL: URL? = URL(string: "http://example.com/analytics"),
        alternateURL: URL? = URL(string: "http://example.com/alternate"),
        relatedWorksURL: URL? = URL(string: "http://example.com/related"),
        previewLink: TPPOPDSAcquisition? = nil,
        seriesURL: URL? = URL(string: "http://example.com/series"),
        revokeURL: URL? = URL(string: "http://example.com/revoke"),
        reportURL: URL? = URL(string: "http://example.com/report"),
        timeTrackingURL: URL? = URL(string: "http://example.com/timetracking"),
        contributors: [String: Any]? = nil,
        bookDuration: String? = nil
    ) -> TPPBook {
        let acq = acquisitions ?? [TPPFake.genericAcquisition]
        return TPPBook(
            acquisitions: acq,
            authors: authors,
            categoryStrings: categoryStrings,
            distributor: distributor,
            identifier: identifier,
            imageURL: imageURL,
            imageThumbnailURL: imageThumbnailURL,
            published: published,
            publisher: publisher,
            subtitle: subtitle,
            summary: summary,
            title: title,
            updated: updated,
            annotationsURL: annotationsURL,
            analyticsURL: analyticsURL,
            alternateURL: alternateURL,
            relatedWorksURL: relatedWorksURL,
            previewLink: previewLink,
            seriesURL: seriesURL,
            revokeURL: revokeURL,
            reportURL: reportURL,
            timeTrackingURL: timeTrackingURL,
            contributors: contributors,
            bookDuration: bookDuration,
            imageCache: MockImageCache()
        )
    }

    // MARK: - Dictionary Round-Trip: Required Keys

    func test_dictionaryRepresentation_containsRequiredKeys() {
        let book = makeBook()
        let dict = book.dictionaryRepresentation()

        XCTAssertEqual(dict[IdentifierKey] as? String, "test-id")
        XCTAssertEqual(dict[TitleKey] as? String, "Test Title")
        XCTAssertNotNil(dict[UpdatedKey] as? String)
        XCTAssertNotNil(dict[CategoriesKey])
        XCTAssertNotNil(dict[AcquisitionsKey])
    }

    func test_dictionaryRoundTrip_preservesIdentifierAndTitle() {
        let book = makeBook(identifier: "round-trip-id", title: "Round Trip Title")
        let dict = book.dictionaryRepresentation()
        let restored = TPPBook(dictionary: dict)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.identifier, "round-trip-id")
        XCTAssertEqual(restored?.title, "Round Trip Title")
    }

    func test_dictionaryRoundTrip_preservesOptionalURLs() {
        let book = makeBook(
            annotationsURL: URL(string: "http://example.com/ann"),
            revokeURL: URL(string: "http://example.com/rev"),
            reportURL: URL(string: "http://example.com/rep"),
            timeTrackingURL: URL(string: "http://example.com/tt")
        )
        let dict = book.dictionaryRepresentation()

        XCTAssertEqual(dict[AnnotationsURLKey] as? String, "http://example.com/ann")
        XCTAssertEqual(dict[RevokeURLKey] as? String, "http://example.com/rev")
        XCTAssertEqual(dict[ReportURLKey] as? String, "http://example.com/rep")
        XCTAssertEqual(dict[TimeTrackingURLURLKey] as? String, "http://example.com/tt")
    }

    func test_dictionaryRoundTrip_preservesAuthors() {
        let authors = [
            TPPBookAuthor(authorName: "Jane Doe", relatedBooksURL: URL(string: "http://example.com/jane")),
            TPPBookAuthor(authorName: "John Smith", relatedBooksURL: nil)
        ]
        let book = makeBook(authors: authors)
        let restored = TPPBook(dictionary: book.dictionaryRepresentation())

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.bookAuthors?.count, 2)
        XCTAssertEqual(restored?.bookAuthors?[0].name, "Jane Doe")
        XCTAssertEqual(restored?.bookAuthors?[1].name, "John Smith")
    }

    func test_dictionaryRoundTrip_preservesCategories() {
        let book = makeBook(categoryStrings: ["Sci-Fi", "Drama"])
        let restored = TPPBook(dictionary: book.dictionaryRepresentation())

        XCTAssertEqual(restored?.categoryStrings, ["Sci-Fi", "Drama"])
    }

    func test_dictionaryRoundTrip_preservesDistributor() {
        let book = makeBook(distributor: "Overdrive")
        let restored = TPPBook(dictionary: book.dictionaryRepresentation())

        XCTAssertEqual(restored?.distributor, "Overdrive")
    }

    func test_dictionaryRoundTrip_preservesSubtitleAndSummary() {
        let book = makeBook(subtitle: "Vol. 1", summary: "An epic tale")
        let restored = TPPBook(dictionary: book.dictionaryRepresentation())

        XCTAssertEqual(restored?.subtitle, "Vol. 1")
        XCTAssertEqual(restored?.summary, "An epic tale")
    }

    // MARK: - Dictionary Init Edge Cases

    func test_dictionaryInit_nilWhenMissingTitle() {
        let book = TPPBook(dictionary: [
            "categories": ["Fiction"],
            "id": "123",
            "updated": "2024-01-01T00:00:00Z"
        ])
        XCTAssertNil(book)
    }

    func test_dictionaryInit_nilWhenMissingId() {
        let book = TPPBook(dictionary: [
            "categories": ["Fiction"],
            "title": "Test",
            "updated": "2024-01-01T00:00:00Z"
        ])
        XCTAssertNil(book)
    }

    func test_dictionaryInit_nilWhenMissingCategories() {
        let book = TPPBook(dictionary: [
            "id": "123",
            "title": "Test",
            "updated": "2024-01-01T00:00:00Z"
        ])
        XCTAssertNil(book)
    }

    func test_dictionaryInit_nilWhenMissingUpdated() {
        let book = TPPBook(dictionary: [
            "categories": ["Fiction"],
            "id": "123",
            "title": "Test"
        ])
        XCTAssertNil(book)
    }

    func test_dictionaryInit_handlesNestedAuthorArrayFormat() {
        // The dictionary init supports both flat and nested author arrays
        let acqs = [TPPFake.genericAcquisition.dictionaryRepresentation()]
        let book = TPPBook(dictionary: [
            "acquisitions": acqs,
            "categories": ["Fiction"],
            "id": "nested-auth",
            "title": "Nested Authors",
            "updated": "2024-01-01T00:00:00Z",
            AuthorsKey: [["Alice", "Bob"]]
        ])

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.bookAuthors?.count, 2)
        XCTAssertEqual(book?.bookAuthors?[0].name, "Alice")
        XCTAssertEqual(book?.bookAuthors?[1].name, "Bob")
    }

    func test_dictionaryInit_handlesFlatAuthorArrayFormat() {
        let acqs = [TPPFake.genericAcquisition.dictionaryRepresentation()]
        let book = TPPBook(dictionary: [
            "acquisitions": acqs,
            "categories": ["Fiction"],
            "id": "flat-auth",
            "title": "Flat Authors",
            "updated": "2024-01-01T00:00:00Z",
            AuthorsKey: ["Alice", "Bob"]
        ])

        XCTAssertNotNil(book)
        XCTAssertEqual(book?.bookAuthors?.count, 2)
    }

    // MARK: - Computed String Properties

    func test_authors_joinsNamesWithSemicolon() {
        let authors = [
            TPPBookAuthor(authorName: "Author A", relatedBooksURL: nil),
            TPPBookAuthor(authorName: "Author B", relatedBooksURL: nil)
        ]
        let book = makeBook(authors: authors)

        XCTAssertEqual(book.authors, "Author A; Author B")
    }

    func test_authors_nilWhenNoAuthors() {
        let book = makeBook(authors: nil)
        XCTAssertNil(book.authors)
    }

    func test_authors_singleAuthor() {
        let book = makeBook(authors: [TPPBookAuthor(authorName: "Solo", relatedBooksURL: nil)])
        XCTAssertEqual(book.authors, "Solo")
    }

    func test_categories_joinsWithSemicolon() {
        let book = makeBook(categoryStrings: ["Horror", "Thriller"])
        XCTAssertEqual(book.categories, "Horror; Thriller")
    }

    func test_categories_nilWhenNil() {
        let book = makeBook(categoryStrings: nil)
        XCTAssertNil(book.categories)
    }

    func test_narrators_joinsContributorsNrt() {
        let book = makeBook(contributors: ["nrt": ["Narrator A", "Narrator B"]])
        XCTAssertEqual(book.narrators, "Narrator A; Narrator B")
    }

    func test_narrators_nilWhenNoContributors() {
        let book = makeBook(contributors: nil)
        XCTAssertNil(book.narrators)
    }

    func test_narrators_nilWhenNoNrtKey() {
        let book = makeBook(contributors: ["trl": ["Translator"]])
        XCTAssertNil(book.narrators)
    }

    // MARK: - Author Arrays

    func test_authorNameArray_returnsNames() {
        let authors = [
            TPPBookAuthor(authorName: "Alice", relatedBooksURL: nil),
            TPPBookAuthor(authorName: "Bob", relatedBooksURL: nil)
        ]
        let book = makeBook(authors: authors)
        XCTAssertEqual(book.authorNameArray, ["Alice", "Bob"])
    }

    func test_authorNameArray_nilWhenNoAuthors() {
        let book = makeBook(authors: nil)
        XCTAssertNil(book.authorNameArray)
    }

    func test_authorLinkArray_returnsURLStrings() {
        let authors = [
            TPPBookAuthor(authorName: "Alice", relatedBooksURL: URL(string: "http://a.com")),
            TPPBookAuthor(authorName: "Bob", relatedBooksURL: URL(string: "http://b.com"))
        ]
        let book = makeBook(authors: authors)
        XCTAssertEqual(book.authorLinkArray, ["http://a.com", "http://b.com"])
    }

    func test_authorLinkArray_excludesNilURLs() {
        let authors = [
            TPPBookAuthor(authorName: "Alice", relatedBooksURL: URL(string: "http://a.com")),
            TPPBookAuthor(authorName: "Bob", relatedBooksURL: nil)
        ]
        let book = makeBook(authors: authors)
        // compactMap filters nils, so only Alice's link should appear
        XCTAssertEqual(book.authorLinkArray, ["http://a.com"])
    }

    // MARK: - isAudiobook / hasDuration

    func test_isAudiobook_trueForAudiobookContentType() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertTrue(book.isAudiobook)
    }

    func test_isAudiobook_falseForEpub() {
        let book = makeBook()
        XCTAssertFalse(book.isAudiobook)
    }

    func test_isAudiobook_falseForPDF() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        XCTAssertFalse(book.isAudiobook)
    }

    func test_hasDuration_trueWhenDurationSet() {
        let book = makeBook(bookDuration: "02:30:00")
        XCTAssertTrue(book.hasDuration)
    }

    func test_hasDuration_falseWhenDurationNil() {
        let book = makeBook(bookDuration: nil)
        XCTAssertFalse(book.hasDuration)
    }

    func test_hasDuration_falseWhenDurationEmpty() {
        let book = makeBook(bookDuration: "")
        XCTAssertFalse(book.hasDuration)
    }

    // MARK: - Default Book Content Type

    func test_defaultBookContentType_epub() {
        let book = makeBook()
        XCTAssertEqual(book.defaultBookContentType, .epub)
    }

    func test_defaultBookContentType_audiobook() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertEqual(book.defaultBookContentType, .audiobook)
    }

    func test_defaultBookContentType_pdf() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        XCTAssertEqual(book.defaultBookContentType, .pdf)
    }

    func test_defaultBookContentType_unsupportedWhenNoAcquisitions() {
        let book = makeBook(acquisitions: [])
        XCTAssertEqual(book.defaultBookContentType, .unsupported)
    }

    // MARK: - Default Acquisition Filters

    func test_defaultAcquisitionIfBorrow_returnsAcquisitionWhenBorrow() {
        let acq = TPPOPDSAcquisition(
            relation: .borrow,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com/borrow")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(acquisitions: [acq])
        XCTAssertNotNil(book.defaultAcquisitionIfBorrow)
    }

    func test_defaultAcquisitionIfBorrow_nilWhenOpenAccess() {
        let acq = TPPOPDSAcquisition(
            relation: .openAccess,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com/open")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(acquisitions: [acq])
        XCTAssertNil(book.defaultAcquisitionIfBorrow)
    }

    func test_defaultAcquisitionIfOpenAccess_returnsWhenOpenAccess() {
        let acq = TPPOPDSAcquisition(
            relation: .openAccess,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com/open")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(acquisitions: [acq])
        XCTAssertNotNil(book.defaultAcquisitionIfOpenAccess)
    }

    func test_defaultAcquisitionIfOpenAccess_nilWhenBorrow() {
        let acq = TPPOPDSAcquisition(
            relation: .borrow,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com/borrow")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(acquisitions: [acq])
        XCTAssertNil(book.defaultAcquisitionIfOpenAccess)
    }

    // MARK: - Expiration / isExpired

    func test_isExpired_falseWhenNoExpiration() {
        let book = makeBook()
        XCTAssertFalse(book.isExpired)
    }

    func test_getExpirationDate_nilForUnlimitedAvailability() {
        let book = makeBook()
        XCTAssertNil(book.getExpirationDate())
    }

    func test_getExpirationDate_returnsDateForLimitedAvailability() {
        let futureDate = Date().addingTimeInterval(86400 * 14)
        let book = TPPBookMocker.mockBookWithLimitedAvailability(
            identifier: "limited-book",
            until: futureDate
        )
        let expiration = book.getExpirationDate()

        XCTAssertNotNil(expiration)
        if let exp = expiration {
            XCTAssertEqual(exp.timeIntervalSince1970, futureDate.timeIntervalSince1970, accuracy: 1.0)
        }
    }

    func test_getExpirationDate_nilWhenUntilDateIsInPast() {
        let pastDate = Date().addingTimeInterval(-86400)
        let acq = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityLimited(
                copiesAvailable: 1,
                copiesTotal: 10,
                since: Date().addingTimeInterval(-86400 * 30),
                until: pastDate
            )
        )
        let book = makeBook(acquisitions: [acq])

        // getExpirationDate only returns dates with timeIntervalSinceNow > 0
        XCTAssertNil(book.getExpirationDate())
    }

    // MARK: - Reservation Details

    func test_getReservationDetails_populatesFromReservedAvailability() {
        let book = TPPBookMocker.snapshotReservedBook(holdPosition: 5)
        let details = book.getReservationDetails()

        XCTAssertEqual(details.holdPosition, 5)
        XCTAssertEqual(details.copiesAvailable, 5)
        // The snapshot uses a fixed past date (Jan 2024), so remaining time is 0
        XCTAssertEqual(details.remainingTime, 0)
        XCTAssertEqual(details.timeUnit, "")
    }

    func test_getReservationDetails_zeroValuesForUnlimitedAvailability() {
        let book = makeBook()
        let details = book.getReservationDetails()

        XCTAssertEqual(details.holdPosition, 0)
        XCTAssertEqual(details.remainingTime, 0)
        XCTAssertEqual(details.timeUnit, "")
        XCTAssertEqual(details.copiesAvailable, 0)
    }

    func test_getReservationDetails_timeUnitSingularForOneDay() {
        // Create a reserved book where until is ~1 day from now
        let tomorrow = Date().addingTimeInterval(86400 * 1.1)
        let acq = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityReserved(
                holdPosition: 1,
                copiesTotal: 3,
                since: Date(),
                until: tomorrow
            )
        )
        let book = makeBook(acquisitions: [acq])
        let details = book.getReservationDetails()

        XCTAssertEqual(details.remainingTime, 1)
        XCTAssertEqual(details.timeUnit, "day")
    }

    func test_getReservationDetails_timeUnitPluralForMultipleDays() {
        let nextWeek = Date().addingTimeInterval(86400 * 7.5)
        let acq = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "http://example.com")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityReserved(
                holdPosition: 2,
                copiesTotal: 5,
                since: Date(),
                until: nextWeek
            )
        )
        let book = makeBook(acquisitions: [acq])
        let details = book.getReservationDetails()

        XCTAssertEqual(details.remainingTime, 7)
        XCTAssertEqual(details.timeUnit, "days")
    }

    // MARK: - Availability Details

    func test_getAvailabilityDetails_populatesForLimitedAvailability() {
        let futureDate = Date().addingTimeInterval(86400 * 7)
        let book = TPPBookMocker.mockBookWithLimitedAvailability(
            identifier: "avail-test",
            until: futureDate
        )
        let details = book.getAvailabilityDetails()

        XCTAssertNotNil(details.availableUntil)
    }

    func test_getAvailabilityDetails_nilForUnlimitedAvailability() {
        let book = makeBook()
        let details = book.getAvailabilityDetails()

        XCTAssertNil(details.availableSince)
        XCTAssertNil(details.availableUntil)
    }

    // MARK: - bookWithMetadata

    func test_bookWithMetadata_preservesSelfIdentifierAndAcquisitions() {
        let selfBook = makeBook(identifier: "self-id", title: "Self Title")
        let metadataBook = makeBook(identifier: "meta-id", title: "Meta Title")

        let merged = selfBook.bookWithMetadata(from: metadataBook)

        XCTAssertEqual(merged.identifier, "self-id")
        XCTAssertEqual(merged.acquisitions.count, selfBook.acquisitions.count)
    }

    func test_bookWithMetadata_takesMetadataFromOtherBook() {
        let selfBook = makeBook(identifier: "self-id", title: "Self Title", subtitle: "Old Sub")
        let metadataBook = makeBook(
            identifier: "meta-id",
            title: "Meta Title",
            authors: [TPPBookAuthor(authorName: "New Author", relatedBooksURL: nil)],
            subtitle: "New Subtitle",
            summary: "New Summary"
        )

        let merged = selfBook.bookWithMetadata(from: metadataBook)

        XCTAssertEqual(merged.title, "Meta Title")
        XCTAssertEqual(merged.subtitle, "New Subtitle")
        XCTAssertEqual(merged.summary, "New Summary")
        XCTAssertEqual(merged.bookAuthors?.first?.name, "New Author")
    }

    func test_bookWithMetadata_preservesSelfRevokeReportAndTimeTrackingURLs() {
        let selfBook = makeBook(
            revokeURL: URL(string: "http://self.com/revoke"),
            reportURL: URL(string: "http://self.com/report"),
            timeTrackingURL: URL(string: "http://self.com/tt")
        )
        let metadataBook = makeBook(
            revokeURL: URL(string: "http://meta.com/revoke"),
            reportURL: URL(string: "http://meta.com/report"),
            timeTrackingURL: URL(string: "http://meta.com/tt")
        )

        let merged = selfBook.bookWithMetadata(from: metadataBook)

        XCTAssertEqual(merged.revokeURL?.absoluteString, "http://self.com/revoke")
        XCTAssertEqual(merged.reportURL?.absoluteString, "http://self.com/report")
        XCTAssertEqual(merged.timeTrackingURL?.absoluteString, "http://self.com/tt")
    }

    func test_bookWithMetadata_takesImageURLsFromMetadataBook() {
        let selfBook = makeBook(imageURL: URL(string: "http://self.com/img"))
        let metadataBook = makeBook(imageURL: URL(string: "http://meta.com/img"))

        let merged = selfBook.bookWithMetadata(from: metadataBook)

        XCTAssertEqual(merged.imageURL?.absoluteString, "http://meta.com/img")
    }

    // MARK: - Comparable

    func test_comparable_ordersById() {
        let bookA = makeBook(identifier: "aaa")
        let bookB = makeBook(identifier: "bbb")

        XCTAssertTrue(bookA < bookB)
        XCTAssertFalse(bookB < bookA)
    }

    func test_comparable_equalIdentifiersNotLessThan() {
        let book1 = makeBook(identifier: "same")
        let book2 = makeBook(identifier: "same")

        XCTAssertFalse(book1 < book2)
        XCTAssertFalse(book2 < book1)
    }

    func test_comparable_sortingMultipleBooks() {
        let bookC = makeBook(identifier: "c")
        let bookA = makeBook(identifier: "a")
        let bookB = makeBook(identifier: "b")

        let sorted = [bookC, bookA, bookB].sorted()

        XCTAssertEqual(sorted.map(\.identifier), ["a", "b", "c"])
    }

    // MARK: - categoryStringsFromCategories

    func test_categoryStringsFromCategories_extractsLabelsFromSimplifiedScheme() {
        let category = TPPOPDSCategory(term: "fiction", label: "Fiction", scheme: URL(string: TPPBook.SimplifiedScheme))

        let result = TPPBook.categoryStringsFromCategories(categories: [category])

        XCTAssertEqual(result, ["Fiction"])
    }

    func test_categoryStringsFromCategories_usesTermWhenNoLabel() {
        let category = TPPOPDSCategory(term: "thriller", label: nil, scheme: nil)

        let result = TPPBook.categoryStringsFromCategories(categories: [category])

        XCTAssertEqual(result, ["thriller"])
    }

    func test_categoryStringsFromCategories_filtersOutUnknownSchemes() {
        let category = TPPOPDSCategory(term: "unknown", label: "Unknown", scheme: URL(string: "http://different-scheme.org/"))

        let result = TPPBook.categoryStringsFromCategories(categories: [category])

        XCTAssertTrue(result.isEmpty)
    }

    func test_categoryStringsFromCategories_includesCategoriesWithNilScheme() {
        let category = TPPOPDSCategory(term: "open", label: "Open", scheme: nil)

        let result = TPPBook.categoryStringsFromCategories(categories: [category])

        XCTAssertEqual(result, ["Open"])
    }

    func test_categoryStringsFromCategories_emptyArrayReturnsEmpty() {
        let result = TPPBook.categoryStringsFromCategories(categories: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - ordinalString

    func test_ordinalString_first() {
        XCTAssertEqual(TPPBook.ordinalString(for: 1), "1st")
    }

    func test_ordinalString_second() {
        XCTAssertEqual(TPPBook.ordinalString(for: 2), "2nd")
    }

    func test_ordinalString_third() {
        XCTAssertEqual(TPPBook.ordinalString(for: 3), "3rd")
    }

    func test_ordinalString_eleventh() {
        XCTAssertEqual(TPPBook.ordinalString(for: 11), "11th")
    }

    func test_ordinalString_twelfth() {
        XCTAssertEqual(TPPBook.ordinalString(for: 12), "12th")
    }

    func test_ordinalString_thirteenth() {
        XCTAssertEqual(TPPBook.ordinalString(for: 13), "13th")
    }

    func test_ordinalString_twentyFirst() {
        XCTAssertEqual(TPPBook.ordinalString(for: 21), "21st")
    }

    func test_ordinalString_hundredAndFirst() {
        XCTAssertEqual(TPPBook.ordinalString(for: 101), "101st")
    }

    // MARK: - clearCachedImages

    func test_clearCachedImages_removesAllKeysFromCache() {
        let cache = MockImageCache()
        let img = UIImage()
        cache.set(img, for: "book-123", expiresIn: nil)
        cache.set(img, for: "book-123_cover", expiresIn: nil)
        cache.set(img, for: "book-123_thumbnail", expiresIn: nil)

        let book = TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil,
            categoryStrings: ["Test"],
            distributor: nil,
            identifier: "book-123",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test",
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
            imageCache: cache
        )

        book.clearCachedImages()

        XCTAssertTrue(cache.removedKeys.contains("book-123"))
        XCTAssertTrue(cache.removedKeys.contains("book-123_cover"))
        XCTAssertTrue(cache.removedKeys.contains("book-123_thumbnail"))
    }

    // MARK: - Sample Acquisition

    func test_sampleAcquisition_returnsPreviewLinkAsFallback() {
        let previewAcq = TPPFake.genericSample
        let book = makeBook(previewLink: previewAcq)

        XCTAssertNotNil(book.sampleAcquisition)
    }

    func test_sampleAcquisition_nilWhenNoSampleOrPreview() {
        let book = makeBook(previewLink: nil)
        // The generic acquisition is not a sample, and there is no previewLink
        // so sampleAcquisition should look for sample/preview relation acquisitions
        // and fall back to previewLink (nil)
        // Whether this is nil depends on the acquisition relation
        let result = book.sampleAcquisition
        // genericAcquisition has relation .generic, not .sample or .preview
        XCTAssertEqual(result, book.previewLink)
    }

    // MARK: - Identifiable

    func test_identifiable_conformance() {
        let book = makeBook(identifier: "id-check")
        // TPPBook conforms to Identifiable via NSObject's ObjectIdentifier
        XCTAssertNotNil(book.id)
    }

    // MARK: - ReservationDetails / AvailabilityDetails Init

    func test_reservationDetails_defaultValues() {
        let details = ReservationDetails()

        XCTAssertEqual(details.holdPosition, 0)
        XCTAssertEqual(details.remainingTime, 0)
        XCTAssertEqual(details.timeUnit, "")
        XCTAssertEqual(details.copiesAvailable, 0)
    }

    func test_availabilityDetails_defaultValues() {
        let details = AvailabilityDetails()

        XCTAssertNil(details.availableSince)
        XCTAssertNil(details.availableUntil)
    }
}
