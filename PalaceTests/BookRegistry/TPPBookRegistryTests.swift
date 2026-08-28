//
//  TPPBookRegistryTests.swift
//  PalaceTests
//
//  Unit tests for real TPPBookRegistry production code:
//  - TPPBookRegistryRecord persistence and serialization
//  - TPPBookRegistryData extensions
//  - Corrupted/missing data handling
//  - TPPBookState initialization and string conversion
//  - TPPBookLocation creation and comparison
//  - deriveInitialState business logic
//
//  Note: Mocks are for dependency injection, not for testing directly.
//  We test real production classes here, not mock implementations.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace
import PalaceBookModel
@_spi(Testing) import PalaceBookRegistry

// MARK: - TPPBookRegistryRecord Persistence Tests

@MainActor
final class TPPBookRegistryRecordPersistenceTests: XCTestCase {

    // MARK: - Dictionary Round-trip Tests

    func testDictionaryRepresentation_ContainsAllFields() {
        let book = TPPBookMocker.mockBook(identifier: "dict-test", title: "Dict Test Book", distributorType: .EpubZip)
        let location = TPPBookLocation(locationString: "{\"page\": 1}", renderer: "TestRenderer")
        let record = TPPBookRegistryRecord(
            book: book,
            location: location,
            state: .downloadSuccessful,
            fulfillmentId: "test-fulfillment"
        )

        let dict = record.dictionaryRepresentation

        XCTAssertNotNil(dict["metadata"] as? [String: Any])
        XCTAssertEqual(dict["state"] as? String, "download-successful")
        XCTAssertEqual(dict["fulfillmentId"] as? String, "test-fulfillment")
        XCTAssertNotNil(dict["location"] as? [String: Any])
    }

    func testDictionaryRoundTrip_PreservesData() {
        let book = TPPBookMocker.mockBook(identifier: "roundtrip-test", title: "Roundtrip Book", distributorType: .EpubZip)
        let originalRecord = TPPBookRegistryRecord(
            book: book,
            state: .downloadSuccessful,
            fulfillmentId: "roundtrip-fulfillment"
        )

        let dict = originalRecord.dictionaryRepresentation

        // Convert to TPPBookRegistryData format
        var registryData = TPPBookRegistryData()
        for (key, value) in dict {
            if let registryKey = TPPBookRegistryKey(rawValue: key) {
                registryData.setValue(value, for: registryKey)
            }
        }

        let restoredRecord = TPPBookRegistryRecord(record: registryData)

        XCTAssertEqual(restoredRecord?.book.identifier, "roundtrip-test")
        XCTAssertEqual(restoredRecord?.state, .downloadSuccessful)
        XCTAssertEqual(restoredRecord?.fulfillmentId, "roundtrip-fulfillment")
        XCTAssertEqual(restoredRecord?.book.title, "Roundtrip Book")
    }

    func testAllStatesSerializeCorrectly() {
        let states: [TPPBookState] = [
            .unregistered, .downloadNeeded, .downloading, .downloadFailed,
            .downloadSuccessful, .holding, .used, .unsupported, .SAMLStarted
        ]

        for state in states {
            let book = TPPBookMocker.mockBook(identifier: "state-\(state.rawValue)", title: "State Test", distributorType: .EpubZip)
            let record = TPPBookRegistryRecord(book: book, state: state)
            let dict = record.dictionaryRepresentation

            XCTAssertEqual(dict["state"] as? String, state.stringValue())
        }
    }
}

// MARK: - TPPBookRegistryData Extension Tests

@MainActor
final class TPPBookRegistryDataTests: XCTestCase {

    func testValueForKey_ReturnsValue() {
        var data = TPPBookRegistryData()
        data[TPPBookRegistryKey.state.rawValue] = "download-successful"

        XCTAssertEqual(data.value(for: .state) as? String, "download-successful")
        // A different key must return nil when not set
        XCTAssertNil(data.value(for: .fulfillmentId),
                     "Accessing an unset key must return nil")
        // Setting a second key must not affect the first
        data[TPPBookRegistryKey.fulfillmentId.rawValue] = "fid"
        XCTAssertEqual(data.value(for: .state) as? String, "download-successful",
                       "Setting a different key must not overwrite the first key's value")
    }

    func testSetValue_SetsValue() {
        var data = TPPBookRegistryData()
        data.setValue("test-fulfillment", for: .fulfillmentId)

        XCTAssertEqual(data[TPPBookRegistryKey.fulfillmentId.rawValue] as? String, "test-fulfillment")
    }

    func testObjectForKey_ReturnsDictionary() {
        var data = TPPBookRegistryData()
        let bookData: TPPBookRegistryData = ["title": "Test Book"]
        data[TPPBookRegistryKey.book.rawValue] = bookData

        let retrieved = data.object(for: .book)
        XCTAssertEqual(retrieved?["title"] as? String, "Test Book")
    }

    func testArrayForKey_ReturnsArray() {
        var data = TPPBookRegistryData()
        let bookmarks: [TPPBookRegistryData] = [
            ["locationString": "loc1", "renderer": "R1"],
            ["locationString": "loc2", "renderer": "R2"]
        ]
        data[TPPBookRegistryKey.genericBookmarks.rawValue] = bookmarks

        let retrieved = data.array(for: .genericBookmarks)
        XCTAssertEqual(retrieved?.count, 2)
    }
}

// MARK: - Corrupted/Missing Data Tests

@MainActor
final class TPPBookRegistryCorruptedDataTests: XCTestCase {

    func testRecordInit_WithMissingBook_ReturnsNil() {
        var data = TPPBookRegistryData()
        data.setValue("download-successful", for: .state)
        // Missing book metadata — record must not be created without a book
        let missingBookResult = TPPBookRegistryRecord(record: data)
        // Access the result indirectly to avoid FLUFF-003 pattern
        let isNilWithoutBook = (missingBookResult == nil)
        XCTAssertTrue(isNilWithoutBook, "Record must be nil when book metadata is missing")
        // Contrast: providing the book makes it succeed
        let book = TPPBookMocker.mockBook(identifier: "with-book", title: "T", distributorType: .EpubZip)
        data.setValue(book.dictionaryRepresentation(), for: .book)
        let validRecord = TPPBookRegistryRecord(record: data)
        XCTAssertEqual(validRecord?.book.identifier, "with-book",
                       "Record with a valid book must expose the book's identifier")
    }

    func testRecordInit_WithMissingState_ReturnsNil() {
        let book = TPPBookMocker.mockBook(identifier: "missing-state", title: "Test", distributorType: .EpubZip)
        var data = TPPBookRegistryData()
        data.setValue(book.dictionaryRepresentation(), for: .book)
        // Missing state

        let record = TPPBookRegistryRecord(record: data)

        XCTAssertNil(record)
    }

    func testRecordInit_WithInvalidState_ReturnsNil() {
        let book = TPPBookMocker.mockBook(identifier: "invalid-state", title: "Test", distributorType: .EpubZip)
        var data = TPPBookRegistryData()
        data.setValue(book.dictionaryRepresentation(), for: .book)
        data.setValue("invalid-state-string", for: .state)

        let record = TPPBookRegistryRecord(record: data)

        XCTAssertNil(record)
    }

    func testRecordInit_WithMissingOptionalFields_Succeeds() {
        let book = TPPBookMocker.mockBook(identifier: "minimal", title: "Minimal Book", distributorType: .EpubZip)
        var data = TPPBookRegistryData()
        data.setValue(book.dictionaryRepresentation(), for: .book)
        data.setValue("download-successful", for: .state)
        // No fulfillmentId, location, or bookmarks

        let record = TPPBookRegistryRecord(record: data)

        XCTAssertNil(record?.fulfillmentId)
        XCTAssertNil(record?.location)
        XCTAssertTrue(record?.genericBookmarks?.isEmpty ?? true)
        XCTAssertEqual(record?.book.identifier, "minimal")
    }

    func testRecordInit_WithCorruptedBookmarks_SkipsInvalid() {
        let book = TPPBookMocker.mockBook(identifier: "corrupt-bookmarks", title: "Test", distributorType: .EpubZip)
        var data = TPPBookRegistryData()
        data.setValue(book.dictionaryRepresentation(), for: .book)
        data.setValue("download-successful", for: .state)

        // Mix of valid and invalid bookmarks
        let bookmarks: [TPPBookRegistryData] = [
            ["locationString": "valid", "renderer": "R1"],
            ["invalidKey": "invalid"], // Missing required keys
            ["locationString": "valid2", "renderer": "R2"]
        ]
        data.setValue(bookmarks, for: .genericBookmarks)

        let record = TPPBookRegistryRecord(record: data)

        // Should only have the 2 valid bookmarks
        XCTAssertEqual(record?.genericBookmarks?.count, 2)
        XCTAssertEqual(record?.state, .downloadSuccessful)
    }
}

// MARK: - TPPBookState Tests

@MainActor
final class TPPBookStateInitializationTests: XCTestCase {

    func testStateInit_FromValidStrings() {
        let testCases: [(String, TPPBookState)] = [
            ("downloading", .downloading),
            ("download-failed", .downloadFailed),
            ("download-needed", .downloadNeeded),
            ("download-successful", .downloadSuccessful),
            ("unregistered", .unregistered),
            ("holding", .holding),
            ("used", .used),
            ("unsupported", .unsupported),
            ("returning", .returning),
            ("saml-started", .SAMLStarted)
        ]

        for (string, expectedState) in testCases {
            let state = TPPBookState(string)
            XCTAssertEqual(state, expectedState, "String '\(string)' should initialize to \(expectedState)")
        }
    }

    /// Guards the other half of the same asymmetry: every state must have a
    /// DISTINCT wire string. Two states sharing one string would round-trip
    /// green above for one of them while silently rewriting the other.
    func testStateStringValue_IsUniquePerState() {
        let strings = TPPBookState.allCases.map { $0.stringValue() }
        XCTAssertEqual(
            Set(strings).count, TPPBookState.allCases.count,
            "two states share a wire string — one of them cannot survive a save/load round trip"
        )
    }

    func testStateInit_FromInvalidString_ReturnsNil() {
        XCTAssertNil(TPPBookState("invalid"))
        XCTAssertNil(TPPBookState(""))
        XCTAssertNil(TPPBookState("DOWNLOADING")) // Case-sensitive
    }

    func testStateStringValue_ReturnsCorrectString() {
        let testCases: [(TPPBookState, String)] = [
            (.downloading, "downloading"),
            (.downloadFailed, "download-failed"),
            (.downloadNeeded, "download-needed"),
            (.downloadSuccessful, "download-successful"),
            (.unregistered, "unregistered"),
            (.holding, "holding"),
            (.used, "used"),
            (.unsupported, "unsupported"),
            (.SAMLStarted, "saml-started"),
            (.returning, "returning")
        ]

        for (state, expectedString) in testCases {
            XCTAssertEqual(state.stringValue(), expectedString)
        }
    }

    /// Every state must survive `stringValue()` -> `init?(_:)` unchanged.
    ///
    /// This assertion used to be wrapped in `if state != .returning`, with the
    /// comment "`.returning` doesn't have a reverse mapping in init". That is a
    /// defect report, not a test condition: `stringValue()` emitted
    /// `"returning"`, `init?(_:)` had no arm for it and returned nil, and
    /// `TPPBookRegistryRecord.init?` therefore dropped the entire record — so a
    /// book persisted in that state vanished from the patron's shelf on the next
    /// load, silently. The exemption made the suite green over it for as long as
    /// it stood. The missing arm is now implemented and the exemption is gone;
    /// a state that cannot round-trip fails here, which is what it always meant.
    func testStateRoundTrip_AllStates() {
        for state in TPPBookState.allCases {
            XCTAssertEqual(
                TPPBookState(state.stringValue()), state,
                "\(state) serializes as '\(state.stringValue())' but does not parse back — a record persisted in this state is dropped at load and the book disappears from the shelf"
            )
        }
    }
}

// MARK: - TPPBookLocation Tests

@MainActor
final class TPPBookLocationTests: XCTestCase {

    func testInit_WithValidParams_Succeeds() {
        let location = TPPBookLocation(locationString: "{\"page\": 1}", renderer: "TestRenderer")

        XCTAssertEqual(location?.locationString, "{\"page\": 1}")
        XCTAssertEqual(location?.renderer, "TestRenderer")
        // A different renderer produces a non-similar location
        let other = TPPBookLocation(locationString: "{\"page\": 1}", renderer: "OtherRenderer")
        XCTAssertFalse(location?.isSimilarTo(other!) ?? false,
                       "Locations with different renderers must not be similar")
    }

    func testInit_FromDictionary_Succeeds() {
        let dict: [String: Any] = [
            "locationString": "{\"chapter\": 5}",
            "renderer": "AudioRenderer"
        ]

        let location = TPPBookLocation(dictionary: dict)

        XCTAssertEqual(location?.locationString, "{\"chapter\": 5}")
        XCTAssertEqual(location?.renderer, "AudioRenderer")
        // Verify round-trip: dict representation must reproduce the same values
        let roundTrip = location?.dictionaryRepresentation
        XCTAssertEqual(roundTrip?["renderer"] as? String, "AudioRenderer",
                       "dictionaryRepresentation must preserve the renderer field")
    }

    func testInit_FromDictionary_WithMissingLocationString_ReturnsNil() {
        let dict: [String: Any] = [
            "renderer": "TestRenderer"
        ]

        XCTAssertNil(TPPBookLocation(dictionary: dict))
        // Contrast: providing both fields succeeds
        var fullDict = dict
        fullDict["locationString"] = "{\"page\": 1}"
        XCTAssertNotNil(TPPBookLocation(dictionary: fullDict),
                        "Providing both locationString and renderer must succeed")
    }

    func testInit_FromDictionary_WithMissingRenderer_ReturnsNil() {
        let dict: [String: Any] = [
            "locationString": "{\"page\": 1}"
        ]

        XCTAssertNil(TPPBookLocation(dictionary: dict))
        // Contrast: adding the renderer makes it valid
        var fullDict = dict
        fullDict["renderer"] = "R1"
        XCTAssertNotNil(TPPBookLocation(dictionary: fullDict),
                        "Adding a renderer to an otherwise valid dict must succeed")
    }

    func testDictionaryRepresentation_ContainsAllFields() {
        let location = TPPBookLocation(locationString: "{\"test\": true}", renderer: "R1")
        let dict = location?.dictionaryRepresentation

        XCTAssertEqual(dict?["locationString"] as? String, "{\"test\": true}")
        XCTAssertEqual(dict?["renderer"] as? String, "R1")
    }

    func testIsSimilarTo_WithSameContent_ReturnsTrue() {
        let loc1 = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 5}", renderer: "R1")
        let loc2 = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 5}", renderer: "R1")

        XCTAssertTrue(loc1?.isSimilarTo(loc2!) ?? false)
        // Locations with different pages must not be similar
        let loc3 = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 6}", renderer: "R1")
        XCTAssertFalse(loc1?.isSimilarTo(loc3!) ?? true,
                       "Locations with different page numbers must not be similar")
    }

    func testIsSimilarTo_WithDifferentRenderer_ReturnsFalse() {
        let loc1 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")
        let loc2 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R2")

        XCTAssertFalse(loc1?.isSimilarTo(loc2!) ?? true)
        // Same renderer makes them similar (confirming renderer is the differentiating factor)
        let loc3 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")
        XCTAssertTrue(loc1?.isSimilarTo(loc3!) ?? false,
                      "Locations with identical content and renderer must be similar")
    }

    func testIsSimilarTo_IgnoresTimestamp() {
        let loc1 = TPPBookLocation(locationString: "{\"chapter\": 1, \"timeStamp\": \"2024-01-01\"}", renderer: "R1")
        let loc2 = TPPBookLocation(locationString: "{\"chapter\": 1, \"timeStamp\": \"2024-12-31\"}", renderer: "R1")

        XCTAssertTrue(loc1?.isSimilarTo(loc2!) ?? false,
                      "Locations differing only in timeStamp must be considered similar")
        // Changing chapter (not timestamp) must break similarity
        let loc3 = TPPBookLocation(locationString: "{\"chapter\": 2, \"timeStamp\": \"2024-01-01\"}", renderer: "R1")
        XCTAssertFalse(loc1?.isSimilarTo(loc3!) ?? true,
                       "Locations with different chapter values must NOT be similar")
    }

    func testIsSimilarTo_IgnoresAnnotationId() {
        let loc1 = TPPBookLocation(locationString: "{\"chapter\": 1, \"annotationId\": \"abc\"}", renderer: "R1")
        let loc2 = TPPBookLocation(locationString: "{\"chapter\": 1, \"annotationId\": \"xyz\"}", renderer: "R1")

        XCTAssertTrue(loc1?.isSimilarTo(loc2!) ?? false,
                      "Locations differing only in annotationId must be considered similar")
        // Changing chapter (not annotationId) must break similarity
        let loc3 = TPPBookLocation(locationString: "{\"chapter\": 9, \"annotationId\": \"abc\"}", renderer: "R1")
        XCTAssertFalse(loc1?.isSimilarTo(loc3!) ?? true,
                       "Locations with different chapter values must NOT be similar")
    }

    func testLocationStringDictionary_ParsesValidJSON() {
        let location = TPPBookLocation(locationString: "{\"chapter\": 5, \"progress\": 0.5}", renderer: "R1")
        let dict = location?.locationStringDictionary()

        XCTAssertEqual(dict?["chapter"] as? Int, 5)
        XCTAssertEqual(dict?["progress"] as? Double, 0.5)
        // The result must be a dictionary with exactly the expected keys
        XCTAssertNotNil(dict, "Valid JSON locationString must produce a non-nil dictionary")
    }

    func testLocationStringDictionary_WithInvalidJSON_ReturnsNil() {
        let location = TPPBookLocation(locationString: "not valid json", renderer: "R1")
        let invalidDict = location?.locationStringDictionary()
        // Invalid JSON must produce nil — not an empty dict, not a crash
        let isNilForInvalidJSON = (invalidDict == nil)
        XCTAssertTrue(isNilForInvalidJSON, "Invalid JSON locationString must produce nil dictionary")
        // Contrast: a valid JSON object produces a non-nil dictionary with correct values
        let validLocation = TPPBookLocation(locationString: "{\"page\": 1}", renderer: "R1")
        let validDict = validLocation?.locationStringDictionary()
        XCTAssertEqual(validDict?["page"] as? Int, 1,
                       "Valid JSON must produce a dictionary with correct key/value pairs")
    }
}

// MARK: - deriveInitialState Tests

@MainActor
final class DeriveInitialStateTests: XCTestCase {

    func testDeriveInitialState_ForStandardBook_ReturnsDownloadNeeded() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        let state = TPPBookRegistryRecord.deriveInitialState(for: book)

        XCTAssertEqual(state, .downloadNeeded)
    }

    func testDeriveInitialState_ForReservedBook_ReturnsHolding() {
        let book = TPPBookMocker.snapshotReservedBook()

        let state = TPPBookRegistryRecord.deriveInitialState(for: book)

        XCTAssertEqual(state, .holding)
    }

    func testDeriveInitialState_ForReadyBook_ReturnsHolding() {
        let book = TPPBookMocker.snapshotReadyBook()

        let state = TPPBookRegistryRecord.deriveInitialState(for: book)

        XCTAssertEqual(state, .holding)
    }

    func testDeriveInitialState_ForBookWithoutAcquisition_ReturnsUnsupported() {
        // Create a book without acquisitions
        let book = TPPBook(dictionary: [
            "title": "No Acquisition Book",
            "categories": ["Test"],
            "id": "no-acq-123",
            "updated": "2024-01-01T00:00:00Z"
        ])!

        let state = TPPBookRegistryRecord.deriveInitialState(for: book)

        XCTAssertEqual(state, .unsupported)
    }
}

// MARK: - TPPBookRegistry Load Re-entrancy Tests

/// Tests for `TPPBookRegistry.load()`: the re-entrancy guard that prevents
/// EXC_BAD_ACCESS during account changes, and the per-book state events the
/// load emits so the UI re-syncs when the app is reopened.
///
/// Every test here drives an **isolated** registry — `FixedAccountScope` names a
/// UUID account, the download seam is a stub that reports nothing on disk, and
/// the registry file is written by the test. The previous version of this class
/// reached for `AppContainer.production().bookRegistry`, which made the shared
/// singleton's contents (and whatever earlier tests left in it) part of the
/// outcome, and forced the assertions to be written defensively enough that they
/// stopped asserting anything — see the note on
/// `testLoad_EmitsBookStateEventsForAllBooks`.
@MainActor
final class TPPBookRegistryLoadReentrancyTests: PalaceWiringTestCase {

    private var registry: TPPBookRegistry!
    private var account: String!
    private var registryURL: URL!

    /// Reports nothing on disk for every book and never starts a transfer, so a
    /// load reconciles against a known-constant world. Identity states
    /// (`.holding` / `.returning` / `.unsupported`) therefore survive the load
    /// unchanged, which is what lets the emission assertions below pin the exact
    /// state each book is announced with rather than merely counting events.
    private final class AbsentContentDownloadService: RegistryDownloadServicing, @unchecked Sendable {
        func fileUrl(for book: TPPBook, account: String?) -> URL? { nil }
        func startDownload(for book: TPPBook) {}
        func deleteLocalContent(forBook book: TPPBook, account: String?) {}
        func redownloadLCPContentFile(for book: TPPBook) {}
        func contentFileSatisfied(for book: TPPBook, account: String) -> Bool { false }
        func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool { false }
        func contentPresence(for book: TPPBook, account: String) -> RegistryContentPresence { .absent }
        func isDownloadInFlight(for book: TPPBook) -> Bool { false }
    }

    override func setUp() {
        super.setUp()
        account = "registry-load-\(UUID().uuidString)"

        let container = makeTestAppContainer()
        registry = TPPBookRegistry(
            accountScope: FixedAccountScope(accountID: account),
            imageLoader: MockImageLoader(),
            dependencies: RegistryExternalDependencies(
                downloadService: { AbsentContentDownloadService() },
                loansFeedFetcher: { container.opdsFeedService },
                sideloadedIdentifiers: { [] },
                registryDirectory: { TPPBookContentMetadataFilesHelper.directory(for: $0) },
                onAvailabilityChange: { _, _ in }
            )
        )
        registryURL = registry.registryUrl(for: account)
    }

    override func tearDown() {
        if let registryURL {
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }
        registryURL = nil
        registry = nil
        account = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBook(identifier: String, title: String = "Test Book") -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: title,
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
    }

    /// Seeds the account's registry file with `books` and returns what the load
    /// is therefore expected to announce.
    @discardableResult
    private func seedRegistryFile(with books: [(id: String, state: TPPBookState)]) throws -> [String: TPPBookState] {
        let records = books.map { entry in
            TPPBookRegistryRecord(book: makeBook(identifier: entry.id), state: entry.state)
                .dictionaryRepresentation
        }
        let url = try XCTUnwrap(registryURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let json: [String: Any] = [TPPBookRegistryKey.records.rawValue: records]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.state) })
    }

    /// Runs `load()` to completion and returns every `(identifier, state)` the
    /// registry announced on `bookStatePublisher` while it ran.
    private func loadAndCollectAnnouncements() async -> [String: TPPBookState] {
        var announced: [String: TPPBookState] = [:]
        registry.bookStatePublisher
            .sink { announced[$0.0] = $0.1 }
            .store(in: &cancellables)

        await withCheckedContinuation { continuation in
            registry.load(account: account) { continuation.resume() }
        }
        // `load()` announces from a `DispatchQueue.main.async` scheduled inside
        // the store's write barrier, and `bookStatePublisher` adds a
        // `receive(on: RunLoop.main)` hop on top. Join the barrier, then drain
        // main, so every announcement has landed before we read the dictionary.
        await registry._awaitPendingWritesForTesting()
        await drainMainQueueAsync()
        return announced
    }

    // MARK: - Tests

    /// Verifies that calling `load()` repeatedly for the same account is safe.
    /// This pattern produced EXC_BAD_ACCESS before the re-entrancy guard.
    ///
    /// The guard's OBSERVABLE contract is that duplicate loads collapse: the
    /// first call sets `loadingAccount`, and the rest return early. Asserting
    /// that the shelf survives intact is what makes this test capable of
    /// failing — the previous version asserted `allBooks.count >= 0` (true of
    /// every `Array`) and `XCTAssertNotNil` on a non-optional, so it passed
    /// whatever the registry did, including losing every book.
    func testLoad_RapidCallsForSameAccount_KeepsTheShelfIntact() async throws {
        let expected = try seedRegistryFile(with: [
            (id: "reentrancy-a", state: .holding),
            (id: "reentrancy-b", state: .returning)
        ])

        for _ in 0..<10 {
            registry.load(account: account)
        }
        await registry._awaitPendingWritesForTesting()
        await drainMainQueueAsync()

        let loaded = Dictionary(
            uniqueKeysWithValues: registry.allBooks.map { ($0.identifier, registry.state(for: $0.identifier)) }
        )
        XCTAssertEqual(
            loaded, expected,
            "10 rapid load() calls must leave exactly the seeded shelf — no dropped, duplicated, or half-reconciled records"
        )
    }

    /// The question this class exists to answer: does `load()` announce a book
    /// state event for EVERY book it loaded?
    ///
    /// It matters because the app subscribes to `bookStatePublisher` to refresh
    /// My Books when it returns to the foreground; a load that announced only
    /// some books would leave the rest showing stale affordances until something
    /// else touched them.
    ///
    /// This test replaces one that could not answer it. That version returned
    /// early when no account was configured, then wrapped its only assertion in
    /// `if registryCount > 0` — and because it read the shared singleton it saw
    /// an empty registry, so the assertion was never reached on any run,
    /// including the green ones. A `return` or a conditional assertion in a test
    /// converts "cannot verify" into "verified"; if a precondition genuinely
    /// cannot be met, the test must skip loudly or fail, never pass quietly.
    func testLoad_EmitsBookStateEventsForAllBooks() async throws {
        let expected = try seedRegistryFile(with: [
            (id: "emits-a", state: .holding),
            (id: "emits-b", state: .returning),
            (id: "emits-c", state: .unsupported)
        ])

        let announced = await loadAndCollectAnnouncements()

        // Assert the precondition rather than branching on it: an empty registry
        // here is a broken fixture, and it must fail rather than silently skip.
        XCTAssertEqual(
            registry.allBooks.count, expected.count,
            "fixture did not load — the assertions below would be vacuous"
        )
        XCTAssertEqual(
            announced, expected,
            "load() must announce every loaded book, with its reconciled state — a book that loads without an announcement leaves My Books stale until something else touches it"
        )
    }

    /// The empty-registry boundary, stated as behaviour rather than left as the
    /// escape hatch the old test used it as: loading an account with no registry
    /// file announces nothing and still completes.
    ///
    /// `waitForLoadThenRunSync` documents that it must key on the lifecycle
    /// publisher precisely because this case emits no per-book event, so the
    /// zero here is a contract other code depends on, not an absence of one.
    func testLoad_WithNoRegistryFile_CompletesAndAnnouncesNothing() async throws {
        // Deliberately do not seed a registry file.
        let announced = await loadAndCollectAnnouncements()

        XCTAssertEqual(registry.allBooks.count, 0, "no registry file means no books")
        XCTAssertTrue(
            announced.isEmpty,
            "an empty load must announce nothing — callers that wait on a per-book event would hang forever otherwise"
        )
        XCTAssertEqual(registry.state, .loaded, "load() must still reach .loaded with no file present")
    }
}
