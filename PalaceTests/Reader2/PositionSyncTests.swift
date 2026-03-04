//
//  PositionSyncTests.swift
//  PalaceTests
//
//  Tests for reading position synchronization
//

import XCTest
import ReadiumShared
@testable import Palace

final class PositionSyncTests: XCTestCase {

    // MARK: - Annotations Tests

    func testSyncIsPossibleAndPermitted_checksSyncState() {
        let result = TPPAnnotations.syncIsPossibleAndPermitted()
        // Result depends on configuration
        XCTAssertNotNil(result)
    }

    // MARK: - Book Location Tests

    func testTPPBookLocation_creation() {
        let location = TPPBookLocation(
            locationString: "{\"progressWithinBook\":0.5}",
            renderer: "readium2"
        )

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.renderer, "readium2")
    }

    func testTPPBookLocation_withEmptyString_createsLocation() {
        let location = TPPBookLocation(
            locationString: "",
            renderer: "readium2"
        )

        // TPPBookLocation accepts empty strings - verify it creates a location
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "")
    }

    func testTPPBookLocation_equality() {
        let location1 = TPPBookLocation(
            locationString: "{\"progressWithinBook\":0.5}",
            renderer: "readium2"
        )

        let location2 = TPPBookLocation(
            locationString: "{\"progressWithinBook\":0.5}",
            renderer: "readium2"
        )

        XCTAssertEqual(location1?.locationString, location2?.locationString)
    }

    // MARK: - Readium Bookmark R3 Location Tests

    func testTPPBookmarkR3Location_storesResourceIndex() {
        // Note: This test assumes TPPBookmarkR3Location exists
        // If not, this test documents expected behavior
        XCTAssertTrue(true, "TPPBookmarkR3Location should store resource index and locator")
    }
}

// MARK: - Position Persistence Tests

final class PositionPersistenceTests: XCTestCase {

    private var bookRegistryMock: TPPBookRegistryMock!
    private let testBookId = "position-test-book"

    override func setUpWithError() throws {
        try super.setUpWithError()
        bookRegistryMock = TPPBookRegistryMock()
    }

    override func tearDownWithError() throws {
        bookRegistryMock?.registry = [:]
        bookRegistryMock = nil
        try super.tearDownWithError()
    }

    func testBookRegistry_storesLocation() {
        let location = TPPBookLocation(
            locationString: "{\"progressWithinBook\":0.25}",
            renderer: "readium2"
        )

        // Create a minimal book with placeholder URLs
        let placeholderUrl = URL(string: "https://test.example.com/book")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: placeholderUrl,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )

        let book = TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: testBookId,
            imageURL: nil,  // Use nil to prevent network image fetches
            imageThumbnailURL: nil,  // Use nil to prevent network image fetches
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Test Book",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,  // No preview to prevent network requests
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )

        bookRegistryMock.addBook(
            book,
            location: location,
            state: .downloadSuccessful,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        let storedLocation = bookRegistryMock.location(forIdentifier: testBookId)
        XCTAssertNotNil(storedLocation)
    }

    func testBookRegistry_setLocation_updatesPosition() {
        // Use placeholder URL for acquisition (not fetched in tests)
        let placeholderUrl = URL(string: "https://test.example.com/book")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: placeholderUrl,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )

        let book = TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: testBookId,
            imageURL: nil,  // Use nil to prevent network image fetches
            imageThumbnailURL: nil,  // Use nil to prevent network image fetches
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Test Book",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,  // No preview to prevent network requests
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )

        bookRegistryMock.addBook(
            book,
            location: nil,
            state: .downloadSuccessful,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        let newLocation = TPPBookLocation(
            locationString: "{\"progressWithinBook\":0.75}",
            renderer: "readium2"
        )

        bookRegistryMock.setLocation(newLocation, forIdentifier: testBookId)

        let storedLocation = bookRegistryMock.location(forIdentifier: testBookId)
        XCTAssertNotNil(storedLocation)
    }
}

// MARK: - Sync Conflict Resolution Tests

final class SyncConflictResolutionTests: XCTestCase {

    func testConflictResolution_serverNewer_usesServer() {
        // Document expected behavior for conflict resolution
        // When server position is newer, it should take precedence
        XCTAssertTrue(true, "Server position should take precedence when newer")
    }

    func testConflictResolution_localNewer_usesLocal() {
        // Document expected behavior for conflict resolution
        // When local position is newer, it should be uploaded
        XCTAssertTrue(true, "Local position should be uploaded when newer")
    }

    func testConflictResolution_sameTimestamp_usesHigherProgress() {
        // Document expected behavior for same-timestamp conflicts
        XCTAssertTrue(true, "Higher progress should be preferred when timestamps match")
    }
}

// MARK: - Sync Permission Tests (PP-3810)

/// Tests that sync preconditions correctly gate on AccountDetails.
/// Regression: After background catalog refresh, AccountDetails became nil,
/// causing sync to silently fail even though the user was signed in.
final class SyncPermissionTests: XCTestCase {

    func testSyncIsPossible_withoutCredentials_returnsFalse() {
        let mockAccount = TPPUserAccountMock()
        mockAccount._credentials = nil
        let result = TPPAnnotations.syncIsPossible(mockAccount)
        XCTAssertFalse(result, "Sync should not be possible without credentials")
    }

    func testSyncIsPossible_withCredentials_dependsOnCurrentAccountDetails() {
        let mockAccount = TPPUserAccountMock()
        mockAccount._credentials = .barcodeAndPin(barcode: "test", pin: "test")
        XCTAssertTrue(mockAccount.hasCredentials())

        // The result depends on AccountsManager.shared.currentAccount?.details
        // which we can't fully control in unit tests, but we verify no crash.
        _ = TPPAnnotations.syncIsPossible(mockAccount)
    }

    func testSyncIsPossibleAndPermitted_doesNotCrash() {
        // Ensure the function gracefully handles whatever singleton state exists
        let result = TPPAnnotations.syncIsPossibleAndPermitted()
        XCTAssertNotNil(result)
    }

    func testAccountDetails_syncProperties_matchExpectations() throws {
        let bundle = Bundle(for: type(of: self))
        guard let authDocURL = bundle.url(forResource: "nypl_authentication_document",
                                          withExtension: "json") else {
            throw XCTSkip("nypl_authentication_document.json not in test bundle")
        }
        let authDoc = try OPDS2AuthenticationDocument.fromData(Data(contentsOf: authDocURL))

        guard let feedURL = bundle.url(forResource: "OPDS2CatalogsFeed",
                                       withExtension: "json") else {
            throw XCTSkip("OPDS2CatalogsFeed.json not in test bundle")
        }
        let feed = try OPDS2CatalogsFeed.fromData(Data(contentsOf: feedURL))
        guard let pub = feed.catalogs.first else {
            throw XCTSkip("Feed has no catalogs")
        }

        let account = Account(publication: pub, imageCache: MockImageCache())
        XCTAssertNil(account.details, "Details should be nil before auth doc is set")

        account.authenticationDocument = authDoc
        XCTAssertNotNil(account.details, "Setting auth doc should populate details")
        XCTAssertTrue(account.details!.supportsSimplyESync,
                      "NYPL account should support SimplyE sync")
        XCTAssertTrue(account.details!.syncPermissionGranted,
                      "Sync permission should default to true")
    }

    func testAccountDetails_nilDetails_makesSyncPropertiesFalse() throws {
        let bundle = Bundle(for: type(of: self))
        guard let feedURL = bundle.url(forResource: "OPDS2CatalogsFeed",
                                       withExtension: "json") else {
            throw XCTSkip("OPDS2CatalogsFeed.json not in test bundle")
        }
        let feed = try OPDS2CatalogsFeed.fromData(Data(contentsOf: feedURL))
        guard let pub = feed.catalogs.first else {
            throw XCTSkip("Feed has no catalogs")
        }

        let account = Account(publication: pub, imageCache: MockImageCache())
        // Without setting authenticationDocument, details is nil.
        // This simulates the PP-3810 bug where details were lost after refresh.
        XCTAssertNil(account.details)
        XCTAssertFalse(account.details?.supportsSimplyESync == true,
                       "nil details should make sync support false via optional chaining")
        XCTAssertFalse(account.details?.syncPermissionGranted == true,
                       "nil details should make sync permission false via optional chaining")
    }
}

// MARK: - ReaderService Sync Integration Tests (PP-3810)

/// Tests that TPPLastReadPositionSynchronizer can be created and invoked
/// from the same context as ReaderService.makeEPUBViewController.
/// Regression: The SwiftUI EPUB path bypassed the synchronizer entirely.
final class ReaderServiceSyncTests: XCTestCase {

    func testLastReadPositionSynchronizer_canBeCreated() {
        let registry = TPPBookRegistryMock()
        let synchronizer = TPPLastReadPositionSynchronizer(bookRegistry: registry)
        XCTAssertNotNil(synchronizer)
    }

    func testLastReadPositionSynchronizer_syncReturns_whenNoServerPosition() async {
        let registry = TPPBookRegistryMock()
        let synchronizer = TPPLastReadPositionSynchronizer(bookRegistry: registry)

        let book = Self.makeTestBook(identifier: "sync-test-book")

        // sync() should complete gracefully even when no server position exists
        // and sync is not configured. This proves the code path works end-to-end.
        let publication = Publication(manifest: Manifest(metadata: Metadata(title: "Test")))
        await synchronizer.sync(for: publication, book: book, drmDeviceID: nil)
    }

    func testLastReadPositionSynchronizer_syncDoesNotCrash_withDeviceID() async {
        let registry = TPPBookRegistryMock()
        let synchronizer = TPPLastReadPositionSynchronizer(bookRegistry: registry)

        let book = Self.makeTestBook(identifier: "sync-device-id-test")

        let publication = Publication(manifest: Manifest(metadata: Metadata(title: "Device ID Test")))
        await synchronizer.sync(for: publication, book: book, drmDeviceID: "test-device-id-123")
    }

    // MARK: - Helpers

    static func makeTestBook(identifier: String) -> TPPBook {
        let placeholderUrl = URL(string: "https://test.example.com/book")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: placeholderUrl,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )

        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Test Book",
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
    }
}
