//
//  AudiobookPositionLibraryPinTests.swift
//  PalaceTests
//
//  PP-5578: the audiobook session saves its local position to the library it was
//  opened from, so a position saved after the patron selects another library is
//  kept on the device and found when the book is reopened offline.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

/// The selected library's id only; no library has account details, so the
/// session's annotation posts send nothing.
private final class SelectedLibrary: NSObject, TPPLibraryAccountsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var selected: String
    private let patron = TPPUserAccountMock()

    init(_ id: String) { selected = id }

    func select(_ id: String) { lock.withLock { selected = id } }

    var currentAccountId: String? { lock.withLock { selected } }
    var tppAccountUUID: String { "" }
    var currentAccount: Account? { nil }
    func account(_ uuid: String) -> Account? { nil }
    func reportSignInProgress(_ progress: SignInProgress) {}
    func userAccount(for libraryUUID: String) -> TPPUserAccount { patron }
    var currentUserAccount: TPPUserAccount { patron }
}

@MainActor
final class AudiobookPositionLibraryPinTests: XCTestCase {

    private let accountA = "pin-A-\(UUID().uuidString)"
    private let accountB = "pin-B-\(UUID().uuidString)"
    private let bookID = "pin-audiobook"
    private var fixture: PositionRegistryFixture!
    private var libraries: SelectedLibrary!
    private var tracks: Tracks!
    private var book: TPPBook!

    override func setUp() async throws {
        try await super.setUp()
        libraries = SelectedLibrary(accountA)
        TPPAnnotations.accountsManagerOverride = libraries
        AnnotationDevice.accountsManagerOverride = libraries
        // A patron who has just signed in to library A: an empty shelf, then a borrow.
        fixture = PositionRegistryFixture(account: accountA)
        await fixture.load(accountA)
        XCTAssertNil(fixture.persistedLocations(accountA), "premise: no registry file before the first borrow")
        book = TPPBookMocker.mockBook(identifier: bookID, title: "Pinned", distributorType: .OpenAccessAudiobook)
        fixture.registry.addBook(book, location: nil, state: .downloadSuccessful, fulfillmentId: nil,
                                 readiumBookmarks: nil, genericBookmarks: nil)
        await fixture.registry._awaitPendingPersistenceForTesting()
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue, bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: bookID, token: nil)
    }

    override func tearDown() async throws {
        await fixture.registry._awaitPendingPersistenceForTesting()
        fixture.removeFiles()
        fixture = nil
        TPPAnnotations.accountsManagerOverride = nil
        AnnotationDevice.accountsManagerOverride = nil
        libraries = nil
        tracks = nil
        book = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var registry: TPPBookRegistry { fixture.registry }

    /// Built the way the audiobook session builds it while library A is selected.
    private func openSession() -> AudiobookBookmarkBusinessLogic {
        AudiobookBookmarkBusinessLogic(book: book, positionTrace: nil, registry: registry,
                                       accountsManager: libraries, debounceInterval: nil)
    }

    private func position(seconds: Double) -> TrackPosition {
        TrackPosition(track: tracks.tracks[1], timestamp: seconds, tracks: tracks)
    }

    private func select(_ account: String) async {
        libraries.select(account)
        fixture.scope.switchTo(account)
        var loaded = false
        for _ in 0..<1000 {
            if registry.loadedAccountID == account { loaded = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(loaded, "premise: \(account) loaded")
        await registry._awaitPendingPersistenceForTesting()
    }

    private func offsetMilliseconds(in location: TPPBookLocation?) throws -> Int? {
        let dict = try XCTUnwrap(location?.locationStringDictionary())
        return try XCTUnwrap(AudioBookmark.create(locatorData: dict)).readingOrderItemOffsetMilliseconds
    }

    private func persistedOffsetInLibraryA() throws -> Int? {
        let string = try XCTUnwrap(fixture.persistedLocations(accountA)?[bookID])
        return try offsetMilliseconds(in: TPPBookLocation(locationString: string, renderer: "test"))
    }

    // MARK: - Tests

    func testSaveListeningPosition_OpenedInLibraryAThenSwitchedToB_IsReadBackInLibraryA() async throws {
        let session = openSession()
        await select(accountB)

        session.saveListeningPosition(at: position(seconds: 42), completion: nil)
        await session._awaitPositionWriteForTesting()
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(try persistedOffsetInLibraryA(), 42_000)
        XCTAssertNil(fixture.persistedLocations(accountB)?[bookID], "library B's file gets no book of A")
        await select(accountA)
        XCTAssertEqual(try offsetMilliseconds(in: registry.location(forIdentifier: bookID)), 42_000,
                       "reopening in library A, offline, starts from the position saved after the switch")
    }

    func testSaveListeningPositionSync_OpenedInLibraryAThenSwitchedToB_IsOnDiskInLibraryA() async throws {
        let session = openSession()
        await select(accountB)

        session.saveListeningPositionSync(at: position(seconds: 73))

        XCTAssertEqual(try persistedOffsetInLibraryA(), 73_000)
    }

    func testSaveListeningPosition_LibraryAStillSelected_IsStoredInLibraryA() async throws {
        let session = openSession()

        session.saveListeningPosition(at: position(seconds: 17), completion: nil)
        await session._awaitPositionWriteForTesting()
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(try offsetMilliseconds(in: registry.location(forIdentifier: bookID)), 17_000)
        XCTAssertEqual(try persistedOffsetInLibraryA(), 17_000)
    }
}
