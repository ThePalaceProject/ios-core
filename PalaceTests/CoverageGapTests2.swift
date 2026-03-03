//
//  CoverageGapTests2.swift
//  PalaceTests
//
//  Additional Coverage coverage gap tests for AppTabRouter, TPPBook, TPPBadgeImage, DebugSettings.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - 1. AppTabRouterGapTests

@MainActor
final class AppTabRouterGapTests: XCTestCase {

    /// Coverage Gap: AppTab enum — verify hashability and all cases exist
    func testAppTab_allCasesExistAndAreHashable() {
        let catalog: AppTab = .catalog
        let myBooks: AppTab = .myBooks
        let holds: AppTab = .holds
        let settings: AppTab = .settings

        var set = Set<AppTab>()
        set.insert(catalog)
        set.insert(myBooks)
        set.insert(holds)
        set.insert(settings)

        XCTAssertEqual(set.count, 4, "All four AppTab cases should be distinct and hashable")
        XCTAssertTrue(set.contains(.catalog))
        XCTAssertTrue(set.contains(.myBooks))
        XCTAssertTrue(set.contains(.holds))
        XCTAssertTrue(set.contains(.settings))
    }

    /// Coverage Gap: AppTabRouter — verify default selected is .catalog
    func testAppTabRouter_defaultSelected_isCatalog() {
        let router = AppTabRouter()

        XCTAssertEqual(router.selected, .catalog,
                       "AppTabRouter default selected tab should be .catalog")
    }

    /// Coverage Gap: AppTabRouter — verify selected can be changed
    func testAppTabRouter_selected_canBeChanged() {
        let router = AppTabRouter()

        router.selected = .myBooks
        XCTAssertEqual(router.selected, .myBooks)

        router.selected = .holds
        XCTAssertEqual(router.selected, .holds)

        router.selected = .settings
        XCTAssertEqual(router.selected, .settings)

        router.selected = .catalog
        XCTAssertEqual(router.selected, .catalog)
    }

    /// Coverage Gap: AppTabRouterHub — verify shared singleton exists
    func testAppTabRouterHub_shared_singletonExists() {
        let hub = AppTabRouterHub.shared

        XCTAssertNotNil(hub, "AppTabRouterHub.shared singleton should exist")
        XCTAssertTrue(hub === AppTabRouterHub.shared,
                      "AppTabRouterHub.shared should return same instance")
    }
}

// MARK: - 2. TPPBookModelGapTests

final class TPPBookModelGapTests: XCTestCase {

    /// Coverage Gap: TPPBook dictionaryRepresentation — produces non-empty dict
    func testTPPBook_dictionaryRepresentation_producesNonEmptyDict() {
        let book = TPPBookMocker.mockBook(
            identifier: "dict-test-001",
            title: "Dictionary Test Book",
            distributorType: .EpubZip
        )

        let dict = book.dictionaryRepresentation()

        XCTAssertFalse(dict.isEmpty, "dictionaryRepresentation should produce non-empty dict")
        XCTAssertEqual(dict[IdentifierKey] as? String, "dict-test-001")
        XCTAssertEqual(dict[TitleKey] as? String, "Dictionary Test Book")
        XCTAssertNotNil(dict[CategoriesKey])
        XCTAssertNotNil(dict[AcquisitionsKey])
    }

    /// Coverage Gap: TPPBook dictionaryRepresentation — round-trip preserves key properties
    func testTPPBook_dictionaryRepresentation_roundTripPreservesKeyProperties() {
        let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
        let inputDict: [String: Any] = [
            AcquisitionsKey: acquisitions,
            CategoriesKey: ["Fiction"],
            IdentifierKey: "roundtrip-001",
            TitleKey: "Round Trip Book",
            UpdatedKey: "2024-01-15T12:00:00Z"
        ]

        guard let book = TPPBook(dictionary: inputDict) else {
            XCTFail("Failed to create book from input dict")
            return
        }

        let dict = book.dictionaryRepresentation()
        let recreated = TPPBook(dictionary: dict)

        XCTAssertNotNil(recreated, "Book should be recreated from dictionaryRepresentation")
        XCTAssertEqual(recreated?.identifier, book.identifier)
        XCTAssertEqual(recreated?.title, book.title)
        XCTAssertEqual(recreated?.categoryStrings, book.categoryStrings)
    }

    /// Coverage Gap: TPPBook equality — same identifier yields equivalent Comparable result
    func testTPPBook_sameIdentifier_comparableEquivalent() {
        let book1 = TPPBookMocker.mockBook(identifier: "equal-001", title: "A")
        let book2 = TPPBookMocker.mockBook(identifier: "equal-001", title: "B")

        // Comparable: two books with same identifier should be neither < nor >
        XCTAssertFalse(book1 < book2, "Same identifier: book1 should not be less than book2")
        XCTAssertFalse(book2 < book1, "Same identifier: book2 should not be less than book1")
    }

    /// Coverage Gap: TPPBook bookWithMetadata — returns book with updated metadata from source
    func testTPPBook_bookWithMetadata_returnsBookWithUpdatedMetadata() {
        let sourceBook = TPPBookMocker.mockBook(
            identifier: "metadata-source",
            title: "Source Title"
        )
        let acqBook = TPPBookMocker.mockBook(
            identifier: "metadata-acq",
            title: "Acquisition Title"
        )

        let result = acqBook.bookWithMetadata(from: sourceBook)

        // bookWithMetadata keeps self's acquisitions, identifier, revokeURL, reportURL, timeTrackingURL, imageCache
        // but takes metadata (authors, categories, distributor, imageURL, etc.) from the source book
        XCTAssertEqual(result.identifier, acqBook.identifier)
        XCTAssertEqual(result.title, sourceBook.title)
        XCTAssertEqual(result.bookAuthors?.first?.name, sourceBook.bookAuthors?.first?.name)
    }
}

// MARK: - 3. TPPBadgeImageGapTests

final class TPPBadgeImageGapTests: XCTestCase {

    /// Coverage Gap: TPPBadgeImage.audiobook — assetName returns "AudiobookBadge"
    func testTPPBadgeImage_audiobook_assetNameReturnsAudiobookBadge() {
        let audiobook = TPPContentBadgeImageView.TPPBadgeImage.audiobook

        XCTAssertEqual(audiobook.assetName(), "AudiobookBadge")
    }

    /// Coverage Gap: TPPBadgeImage — all badge cases are enumerable
    func testTPPBadgeImage_allCases_areEnumerable() {
        // TPPBadgeImage is Int-backed; we enumerate known cases without calling .ebook.assetName()
        let audiobook: TPPContentBadgeImageView.TPPBadgeImage = .audiobook
        let _: TPPContentBadgeImageView.TPPBadgeImage = .ebook

        XCTAssertEqual(audiobook.rawValue, 0)
        XCTAssertEqual(TPPContentBadgeImageView.TPPBadgeImage.ebook.rawValue, 1)
    }
}

// MARK: - 4. DebugSettingsGapTests

#if DEBUG

final class DebugSettingsGapTests: XCTestCase {

    override func tearDown() {
        // Restore DebugSettings to default state after each test
        DebugSettings.shared.resetAll()
        super.tearDown()
    }

    /// Coverage Gap: DebugSettings — isBorrowErrorSimulationEnabled reflects simulatedBorrowError
    func testDebugSettings_isBorrowErrorSimulationEnabled_reflectsSimulatedBorrowError() {
        let settings = DebugSettings.shared

        settings.simulatedBorrowError = .none
        XCTAssertFalse(settings.isBorrowErrorSimulationEnabled)

        settings.simulatedBorrowError = .loanLimitReached
        XCTAssertTrue(settings.isBorrowErrorSimulationEnabled)
    }

    /// Coverage Gap: DebugSettings — isTestHoldsEnabled reflects testHoldsConfiguration
    func testDebugSettings_isTestHoldsEnabled_reflectsTestHoldsConfiguration() {
        let settings = DebugSettings.shared

        settings.testHoldsConfiguration = .none
        XCTAssertFalse(settings.isTestHoldsEnabled)

        settings.testHoldsConfiguration = .oneReserved
        XCTAssertTrue(settings.isTestHoldsEnabled)
    }

    /// Coverage Gap: DebugSettings — isBadgeLoggingEnabled can be toggled
    func testDebugSettings_isBadgeLoggingEnabled_canBeToggled() {
        let settings = DebugSettings.shared

        settings.isBadgeLoggingEnabled = true
        XCTAssertTrue(settings.isBadgeLoggingEnabled)

        settings.isBadgeLoggingEnabled = false
        XCTAssertFalse(settings.isBadgeLoggingEnabled)
    }

    /// Coverage Gap: DebugSettings resetAll — clears all state
    func testDebugSettings_resetAll_clearsState() {
        let settings = DebugSettings.shared

        settings.simulatedBorrowError = .loanLimitReached
        settings.isBadgeLoggingEnabled = true
        settings.testHoldsConfiguration = .mixedHolds

        settings.resetAll()

        XCTAssertEqual(settings.simulatedBorrowError, .none)
        XCTAssertFalse(settings.isBadgeLoggingEnabled)
        XCTAssertEqual(settings.testHoldsConfiguration, .none)
    }
}

#endif
