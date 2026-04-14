//
//  CoverageGapTests2.swift
//  PalaceTests
//
//  Additional Coverage coverage gap tests for AppTabRouter, TPPBook, TPPBadgeImage, DebugSettings.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - 1. AppTabRouterGapTests

@MainActor
final class AppTabRouterGapTests: XCTestCase {

    /// AppTabRouter publishes a change event for every tab switch — confirms
    /// the router's Combine publisher is wired correctly so SwiftUI views
    /// redraw when the selected tab changes.
    func testAppTabRouter_tabSwitchPublishesChangeEvent() {
        let router = AppTabRouter()
        var receivedValues: [AppTab] = []
        let cancellable = router.$selected.dropFirst().sink { receivedValues.append($0) }
        defer { _ = cancellable }

        router.selected = .myBooks
        router.selected = .holds

        XCTAssertEqual(receivedValues, [.myBooks, .holds],
                       "Each tab assignment must publish the new value via $selected")
    }

    /// AppTabRouter starts at .catalog. Switching to a different tab and back
    /// must result in objectWillChange firing both times — verifying round-trip
    /// navigation emits the correct number of change events.
    func testAppTabRouter_roundTripToDefaultEmitsTwoChangeEvents() {
        let router = AppTabRouter()
        var changeCount = 0
        let cancellable = router.objectWillChange.sink { changeCount += 1 }
        defer { _ = cancellable }

        router.selected = .settings   // change 1
        router.selected = .catalog    // change 2 (back to default)

        XCTAssertEqual(changeCount, 2, "Switching away and back should produce exactly two change events")
        XCTAssertEqual(router.selected, .catalog)
    }

    /// AppTabRouterHub returns to default state (no registered router) after
    /// the injected router is released — confirms the weak reference semantics.
    func testAppTabRouterHub_registeredRouterIsWeaklyHeld() {
        let hub = AppTabRouterHub.shared
        // Reset any previous router assignment
        hub.router = nil

        var router: AppTabRouter? = AppTabRouter()
        hub.router = router
        XCTAssertNotNil(hub.router)

        router = nil
        XCTAssertNil(hub.router,
                     "Hub's router reference is weak; it must become nil when the router is deallocated")
    }

    /// Coverage Gap: AppTabRouterHub — verify shared singleton exists
    func testAppTabRouterHub_shared_singletonExists() {
        let hub = AppTabRouterHub.shared

        XCTAssertNotNil(hub, "AppTabRouterHub.shared singleton should exist")
        XCTAssertTrue(hub === AppTabRouterHub.shared,
                      "AppTabRouterHub.shared should return same instance")
        // Verify hub can accept a router assignment without crashing
        let router = AppTabRouter()
        hub.router = router
        XCTAssertNotNil(hub.router, "Hub should hold the assigned router")
        // Cleanup
        hub.router = nil
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
        // Asset name should be non-empty
        XCTAssertFalse(audiobook.assetName().isEmpty, "AudiobookBadge asset name should not be empty")
        // Asset name should be deterministic across calls
        XCTAssertEqual(audiobook.assetName(), audiobook.assetName(),
                       "AudiobookBadge asset name should be consistent across calls")
    }

    /// Coverage Gap: TPPContentBadgeImageView — initialising with .audiobook badge
    /// must succeed and produce a non-nil view with the correct background color.
    func testTPPBadgeImageView_audiobook_initSucceeds() {
        let view = TPPContentBadgeImageView(badgeImage: .audiobook)

        XCTAssertNotNil(view, "TPPContentBadgeImageView should initialise with .audiobook without crashing")
        XCTAssertEqual(view.backgroundColor, TPPConfiguration.audiobookIconColor(),
                       "Badge view background should match the audiobookIconColor configuration")
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

    /// Coverage Gap: DebugSettings — resetAll clears isBadgeLoggingEnabled
    /// even when it was explicitly set to true before the reset call.
    func testDebugSettings_resetAll_clearsBadgeLogging() {
        let settings = DebugSettings.shared

        // Arrange: put settings into a known dirty state
        settings.isBadgeLoggingEnabled = true
        XCTAssertTrue(settings.isBadgeLoggingEnabled, "Pre-condition: badge logging should be enabled before reset")

        // Act
        settings.resetAll()

        // Assert: resetAll must clear it
        XCTAssertFalse(settings.isBadgeLoggingEnabled,
                       "resetAll() must set isBadgeLoggingEnabled back to false")
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
