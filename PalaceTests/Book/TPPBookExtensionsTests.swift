//
//  TPPBookExtensionsTests.swift
//  PalaceTests
//
//  Tests for TPPBook+Extensions: format string, hasSample, hasAudiobookSample,
//  showAudiobookToolbar, sample factory property, and loggable helpers.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class TPPBookExtensionsTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a book via the dictionary init for a known acquisition + optional sample.
    private func makeBook(
        acquisition: TPPOPDSAcquisition = TPPFake.genericAcquisition,
        previewLink: TPPOPDSAcquisition? = nil
    ) -> TPPBook {
        let acquisitions = [acquisition.dictionaryRepresentation()]
        var dict: [String: Any] = [
            "acquisitions": acquisitions,
            "categories": ["Test"],
            "id": "ext-test-\(UUID().uuidString)",
            "title": "Test Book",
            "updated": "2024-01-01T00:00:00Z"
        ]
        if let previewLink = previewLink {
            dict["preview-url"] = previewLink.dictionaryRepresentation()
        }
        return TPPBook(dictionary: dict)!
    }

    // MARK: - format

    func test_format_forEpub_matchesLocalizedString() {
        let book = makeBook(acquisition: TPPFake.genericAcquisition)
        XCTAssertEqual(book.defaultBookContentType, .epub)
        XCTAssertEqual(book.format, Strings.TPPBook.epubContentType)
    }

    func test_format_forAudiobook_matchesLocalizedString() {
        let book = makeBook(acquisition: TPPFake.genericAudiobookAcquisition)
        XCTAssertEqual(book.defaultBookContentType, .audiobook)
        XCTAssertEqual(book.format, Strings.TPPBook.audiobookContentType)
    }

    func test_format_forUnsupported_matchesLocalizedString() {
        // Book with no acquisitions -> unsupported content type
        let book = TPPBook(
            acquisitions: [],
            authors: nil,
            categoryStrings: ["Test"],
            distributor: nil,
            identifier: "unsupported-fmt",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Unsupported",
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
        XCTAssertEqual(book.format, Strings.TPPBook.unsupportedContentType)
    }

    func test_format_forPDF_matchesLocalizedString() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        XCTAssertEqual(book.format, Strings.TPPBook.pdfContentType)
    }

    /// `format` is a localized user-facing label. Lock both the
    /// non-emptiness invariant AND a couple of distinct content-type
    /// outputs in one body — the localized strings differ between
    /// ePub/Audiobook/PDF, so a mutant that always returns a constant
    /// fails the inequality cross-check.
    func test_format_isNonEmptyAndDistinguishableAcrossContentTypes() {
        let epub = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let pdf = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        let audiobook = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        XCTAssertFalse(epub.format.isEmpty,      "epub.format must be non-empty")
        XCTAssertFalse(pdf.format.isEmpty,       "pdf.format must be non-empty")
        XCTAssertFalse(audiobook.format.isEmpty, "audiobook.format must be non-empty")

        // Distinct content types must yield distinct labels — guards a
        // mutant that returns the same constant from every branch.
        let formats = Set([epub.format, pdf.format, audiobook.format])
        XCTAssertGreaterThanOrEqual(formats.count, 2,
                                    "At least two of (epub, pdf, audiobook) must yield distinct format strings")
    }

    // MARK: - hasSample

    /// `hasSample` is true iff the book has a usable preview path. Lock
    /// both branches (no sample, with sample) in one body and pin the
    /// hasAudiobookSample distinction so a mutant that conflates the two
    /// flags is caught.
    func test_hasSample_returnsTrueOnlyWhenSampleIsPresent_andDistinguishesAudiobook() {
        let plainEpub = makeBook()
        let epubWithSample = makeBook(previewLink: TPPFake.genericSample)

        XCTAssertFalse(plainEpub.hasSample,
                       "Plain epub without preview must not claim hasSample")
        XCTAssertTrue(epubWithSample.hasSample,
                      "Epub with previewLink MUST claim hasSample")

        // hasSample must NOT be aliased to hasAudiobookSample — an epub
        // with a (non-audiobook) sample must not flip the audiobook flag.
        XCTAssertFalse(epubWithSample.hasAudiobookSample,
                       "Epub sample must NOT trip the audiobook-sample flag — distinct branches in production")
    }

    func test_hasSample_withMockerHasSampleTrue_returnsTrue() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip, hasSample: true)
        XCTAssertTrue(book.hasSample)
    }

    func test_hasSample_withMockerHasSampleFalse_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip, hasSample: false)
        XCTAssertFalse(book.hasSample)
    }

    // MARK: - hasAudiobookSample

    func test_hasAudiobookSample_epubWithSample_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip, hasSample: true)
        // epub is not an audiobook, so even with a sample, this should be false
        XCTAssertFalse(book.hasAudiobookSample)
    }

    func test_hasAudiobookSample_audiobookWithSample_returnsTrue() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook, hasSample: true)
        XCTAssertTrue(book.hasAudiobookSample)
    }

    func test_hasAudiobookSample_audiobookWithoutSample_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook, hasSample: false)
        XCTAssertFalse(book.hasAudiobookSample)
    }

    func test_hasAudiobookSample_pdfWithSample_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF, hasSample: true)
        XCTAssertFalse(book.hasAudiobookSample)
    }

    // MARK: - showAudiobookToolbar

    func test_showAudiobookToolbar_falseWhenNoSample() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook, hasSample: false)
        XCTAssertFalse(book.showAudiobookToolbar)
    }

    func test_showAudiobookToolbar_falseForEpubEvenWithSample() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip, hasSample: true)
        XCTAssertFalse(book.showAudiobookToolbar)
    }

    // MARK: - sample factory property

    func test_sample_withEpubSample_returnsEpubSample() {
        let book = makeBook(previewLink: TPPFake.genericSample)
        let sample = book.sample

        XCTAssertNotNil(sample)
        XCTAssertTrue(sample is EpubSample)
    }

    func test_sample_withAudiobookSample_returnsAudiobookSample() {
        let book = makeBook(
            acquisition: TPPFake.genericAudiobookAcquisition,
            previewLink: TPPFake.genericAudiobookSample
        )
        let sample = book.sample

        XCTAssertNotNil(sample)
        XCTAssertTrue(sample is AudiobookSample)
    }

    /// `sample` factory yields nil when there's nothing to play. Pair the
    /// no-preview case with the no-acquisition case so a mutant that
    /// short-circuits the wrong branch is caught.
    func test_sample_returnsNilWhenNoSampleIsAvailable() {
        // Plain book — no preview link.
        XCTAssertNil(makeBook().sample,
                     "Book without previewLink must yield nil sample")

        // Book with empty acquisitions — even a previewLink can't be played.
        let bookWithNoAcquisitions = TPPBook(
            acquisitions: [],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Test"],
            distributor: nil,
            identifier: "no-acq",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "No Acquisitions",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: TPPFake.genericSample,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
        XCTAssertNil(bookWithNoAcquisitions.sample,
                     "previewLink without acquisitions must NOT yield a sample — content type can't be derived")
    }

    func test_sample_nilForUnsupportedContentType() {
        // A book with no acquisitions -> unsupported -> nil sample even with previewLink
        let sampleAcq = TPPFake.genericSample
        let book = TPPBook(
            acquisitions: [],
            authors: nil,
            categoryStrings: ["Test"],
            distributor: nil,
            identifier: "unsupported-sample",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Unsupported",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: sampleAcq,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )

        XCTAssertNil(book.sample)
    }

    func test_sample_preservesURL() {
        let sampleURL = URL(string: "http://example.com/my-sample.epub")!
        let sampleAcq = TPPOPDSAcquisition(
            relation: .sample,
            type: "application/epub+zip",
            hrefURL: sampleURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil,
            categoryStrings: ["Test"],
            distributor: nil,
            identifier: "sample-url-test",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Sample URL Test",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: sampleAcq,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )

        XCTAssertEqual(book.sample?.url, sampleURL)
    }

    // MARK: - Loggable helpers

    func test_loggableShortString_containsTitleAndId() {
        let book = makeBook()
        let log = book.loggableShortString()
        XCTAssertTrue(log.contains("Test Book"))
        XCTAssertTrue(log.contains("ext-test-"))
    }

    func test_loggableDictionary_containsExpectedKeys() {
        let book = makeBook()
        let dict = book.loggableDictionary()
        XCTAssertNotNil(dict["bookTitle"])
        XCTAssertNotNil(dict["bookID"])
    }
}
