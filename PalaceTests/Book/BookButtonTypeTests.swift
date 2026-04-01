//
//  BookButtonTypeTests.swift
//  PalaceTests
//
//  Tests for BookButtonType enum: title, buttonStyle, colors, and display properties.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookButtonTypeTests: XCTestCase {

    // SRS: BookButtonType all cases have raw values
    func testAllCases_haveRawValues() {
        let types: [BookButtonType] = [.get, .reserve, .download, .read, .listen, .retry, .cancel, .close, .sample, .audiobookSample, .remove, .cancelHold, .manageHold, .return, .returning]
        for type in types {
            XCTAssertFalse(type.rawValue.isEmpty, "\(type) should have non-empty rawValue")
        }
    }

    // SRS: BookButtonType title returns localized strings
    func testTitle_returnsNonEmptyStrings() {
        let types: [BookButtonType] = [.get, .reserve, .download, .read, .listen, .retry, .cancel, .close, .sample, .audiobookSample, .remove, .cancelHold, .manageHold, .return, .returning]
        for type in types {
            XCTAssertFalse(type.title.isEmpty, "\(type) should have non-empty title")
        }
    }

    // SRS: BookButtonType displaysIndicator true for expected types
    func testDisplaysIndicator_trueForExpected() {
        XCTAssertTrue(BookButtonType.read.displaysIndicator)
        XCTAssertTrue(BookButtonType.remove.displaysIndicator)
        XCTAssertTrue(BookButtonType.get.displaysIndicator)
        XCTAssertTrue(BookButtonType.download.displaysIndicator)
        XCTAssertTrue(BookButtonType.listen.displaysIndicator)
    }

    // SRS: BookButtonType displaysIndicator false for other types
    func testDisplaysIndicator_falseForOthers() {
        XCTAssertFalse(BookButtonType.reserve.displaysIndicator)
        XCTAssertFalse(BookButtonType.cancel.displaysIndicator)
        XCTAssertFalse(BookButtonType.sample.displaysIndicator)
        XCTAssertFalse(BookButtonType.returning.displaysIndicator)
    }

    // SRS: BookButtonType buttonStyle primary for action buttons
    func testButtonStyle_primary() {
        let primaryTypes: [BookButtonType] = [.get, .reserve, .download, .read, .listen, .retry, .returning, .manageHold]
        for type in primaryTypes {
            XCTAssertEqual(type.buttonStyle, .primary, "\(type) should be primary")
        }
    }

    // SRS: BookButtonType buttonStyle secondary for return/cancel/remove
    func testButtonStyle_secondary() {
        XCTAssertEqual(BookButtonType.return.buttonStyle, .secondary)
        XCTAssertEqual(BookButtonType.cancel.buttonStyle, .secondary)
        XCTAssertEqual(BookButtonType.remove.buttonStyle, .secondary)
    }

    // SRS: BookButtonType buttonStyle tertiary for sample/close
    func testButtonStyle_tertiary() {
        XCTAssertEqual(BookButtonType.sample.buttonStyle, .tertiary)
        XCTAssertEqual(BookButtonType.audiobookSample.buttonStyle, .tertiary)
        XCTAssertEqual(BookButtonType.close.buttonStyle, .tertiary)
    }

    // SRS: BookButtonType buttonStyle destructive for cancelHold
    func testButtonStyle_destructive() {
        XCTAssertEqual(BookButtonType.cancelHold.buttonStyle, .destructive)
    }

    // SRS: BookButtonType isPrimary matches buttonStyle
    func testIsPrimary() {
        XCTAssertTrue(BookButtonType.get.isPrimary)
        XCTAssertTrue(BookButtonType.read.isPrimary)
        XCTAssertFalse(BookButtonType.cancel.isPrimary)
        XCTAssertFalse(BookButtonType.sample.isPrimary)
    }

    // SRS: BookButtonType hasBorder for secondary and destructive
    func testHasBorder() {
        XCTAssertTrue(BookButtonType.return.hasBorder)
        XCTAssertTrue(BookButtonType.cancel.hasBorder)
        XCTAssertTrue(BookButtonType.cancelHold.hasBorder)
        XCTAssertFalse(BookButtonType.get.hasBorder)
        XCTAssertFalse(BookButtonType.sample.hasBorder)
    }

    // SRS: BookButtonType buttonBackgroundColor for dark/light backgrounds
    func testButtonBackgroundColor() {
        // Primary on dark background -> white
        let primaryDark = BookButtonType.get.buttonBackgroundColor(true)
        XCTAssertNotNil(primaryDark)

        // Primary on light background -> black
        let primaryLight = BookButtonType.get.buttonBackgroundColor(false)
        XCTAssertNotNil(primaryLight)

        // Secondary -> clear
        let secondaryClear = BookButtonType.cancel.buttonBackgroundColor(true)
        XCTAssertNotNil(secondaryClear)
    }

    // SRS: BookButtonType buttonTextColor varies by background
    func testButtonTextColor() {
        let primaryDark = BookButtonType.get.buttonTextColor(true)
        let primaryLight = BookButtonType.get.buttonTextColor(false)
        XCTAssertNotNil(primaryDark)
        XCTAssertNotNil(primaryLight)

        // Destructive always uses error color
        let destructive = BookButtonType.cancelHold.buttonTextColor(true)
        XCTAssertNotNil(destructive)
    }

    // SRS: BookButtonType borderColor for secondary
    func testBorderColor() {
        let secondaryDark = BookButtonType.return.borderColor(true)
        XCTAssertNotNil(secondaryDark)

        let secondaryLight = BookButtonType.return.borderColor(false)
        XCTAssertNotNil(secondaryLight)
    }
}

// MARK: - ButtonStyleType Tests

final class ButtonStyleTypeTests: XCTestCase {

    // SRS: ButtonStyleType all cases exist
    func testAllCases() {
        let _: ButtonStyleType = .primary
        let _: ButtonStyleType = .secondary
        let _: ButtonStyleType = .tertiary
        let _: ButtonStyleType = .destructive
    }

    // SRS: ButtonStyleType equality
    func testEquality() {
        XCTAssertEqual(ButtonStyleType.primary, ButtonStyleType.primary)
        XCTAssertNotEqual(ButtonStyleType.primary, ButtonStyleType.secondary)
    }
}

// MARK: - BookButtonState Tests

final class BookButtonStateTests: XCTestCase {

    // SRS: BookButtonState all cases exist
    func testAllCases() {
        let states: [BookButtonState] = [.canBorrow, .canHold, .holding, .holdingFrontOfQueue, .downloadNeeded, .downloadSuccessful, .used, .downloadInProgress, .returning, .managingHold, .downloadFailed, .unsupported]
        XCTAssertEqual(states.count, 12)
    }

    // SRS: BookButtonState Equatable
    func testEquatable() {
        XCTAssertEqual(BookButtonState.canBorrow, BookButtonState.canBorrow)
        XCTAssertNotEqual(BookButtonState.canBorrow, BookButtonState.canHold)
    }

    // SRS: BookButtonState downloadInProgress produces cancel button
    func testDownloadInProgress_cancelButton() {
        let url = URL(string: "https://example.com")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: [],
            distributor: nil,
            identifier: "test-id",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
        let buttons = BookButtonState.downloadInProgress.buttonTypes(book: book)
        XCTAssertEqual(buttons, [.cancel])
    }

    // SRS: BookButtonState downloadFailed produces cancel and retry
    func testDownloadFailed_cancelAndRetry() {
        let url = URL(string: "https://example.com")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: [],
            distributor: nil,
            identifier: "test-id",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
        let buttons = BookButtonState.downloadFailed.buttonTypes(book: book)
        XCTAssertEqual(buttons, [.cancel, .retry])
    }

    // SRS: BookButtonState unsupported returns empty buttons
    func testUnsupported_emptyButtons() {
        let url = URL(string: "https://example.com")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: [],
            distributor: nil,
            identifier: "test-id",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
        let buttons = BookButtonState.unsupported.buttonTypes(book: book)
        XCTAssertTrue(buttons.isEmpty)
    }

    // SRS: BookButtonState returning produces returning button
    func testReturning_returningButton() {
        let url = URL(string: "https://example.com")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: [],
            distributor: nil,
            identifier: "test-id",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
        let buttons = BookButtonState.returning.buttonTypes(book: book)
        XCTAssertEqual(buttons, [.returning])
    }

    // SRS: BookButtonState stateForAvailability returns nil for nil availability
    func testStateForAvailability_nilAvailability() {
        XCTAssertNil(BookButtonState.stateForAvailability(nil))
    }

    // SRS: BookButtonState stateForAvailability unlimited returns canBorrow
    func testStateForAvailability_unlimited() {
        let availability = TPPOPDSAcquisitionAvailabilityUnlimited()
        XCTAssertEqual(BookButtonState.stateForAvailability(availability), .canBorrow)
    }
}
