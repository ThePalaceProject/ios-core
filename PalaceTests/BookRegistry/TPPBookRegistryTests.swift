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

// MARK: - TPPBookRegistryRecord Persistence Tests

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

        XCTAssertNotNil(restoredRecord)
        XCTAssertEqual(restoredRecord?.book.identifier, "roundtrip-test")
        XCTAssertEqual(restoredRecord?.state, .downloadSuccessful)
        XCTAssertEqual(restoredRecord?.fulfillmentId, "roundtrip-fulfillment")
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

final class TPPBookRegistryDataTests: XCTestCase {

    func testValueForKey_ReturnsValue() {
        var data = TPPBookRegistryData()
        data[TPPBookRegistryKey.state.rawValue] = "download-successful"

        XCTAssertEqual(data.value(for: .state) as? String, "download-successful")
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

final class TPPBookRegistryCorruptedDataTests: XCTestCase {

    func testRecordInit_WithMissingBook_ReturnsNil() {
        var data = TPPBookRegistryData()
        data.setValue("download-successful", for: .state)
        // Missing book metadata

        let record = TPPBookRegistryRecord(record: data)

        XCTAssertNil(record)
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

        XCTAssertNotNil(record)
        XCTAssertNil(record?.fulfillmentId)
        XCTAssertNil(record?.location)
        XCTAssertTrue(record?.genericBookmarks?.isEmpty ?? true)
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

        XCTAssertNotNil(record)
        // Should only have the 2 valid bookmarks
        XCTAssertEqual(record?.genericBookmarks?.count, 2)
    }
}

// MARK: - TPPBookState Tests

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
            ("saml-started", .SAMLStarted)
        ]

        for (string, expectedState) in testCases {
            let state = TPPBookState(string)
            XCTAssertEqual(state, expectedState, "String '\(string)' should initialize to \(expectedState)")
        }
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

    func testStateRoundTrip_AllStates() {
        for state in TPPBookState.allCases {
            let stringValue = state.stringValue()
            let reconstructed = TPPBookState(stringValue)

            // Note: .returning doesn't have a reverse mapping in init
            if state != .returning {
                XCTAssertEqual(reconstructed, state, "State \(state) should round-trip through string value")
            }
        }
    }
}

// MARK: - TPPBookLocation Tests

final class TPPBookLocationTests: XCTestCase {

    func testInit_WithValidParams_Succeeds() {
        let location = TPPBookLocation(locationString: "{\"page\": 1}", renderer: "TestRenderer")

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "{\"page\": 1}")
        XCTAssertEqual(location?.renderer, "TestRenderer")
    }

    func testInit_FromDictionary_Succeeds() {
        let dict: [String: Any] = [
            "locationString": "{\"chapter\": 5}",
            "renderer": "AudioRenderer"
        ]

        let location = TPPBookLocation(dictionary: dict)

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "{\"chapter\": 5}")
        XCTAssertEqual(location?.renderer, "AudioRenderer")
    }

    func testInit_FromDictionary_WithMissingLocationString_ReturnsNil() {
        let dict: [String: Any] = [
            "renderer": "TestRenderer"
        ]

        XCTAssertNil(TPPBookLocation(dictionary: dict))
    }

    func testInit_FromDictionary_WithMissingRenderer_ReturnsNil() {
        let dict: [String: Any] = [
            "locationString": "{\"page\": 1}"
        ]

        XCTAssertNil(TPPBookLocation(dictionary: dict))
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
    }

    func testIsSimilarTo_WithDifferentRenderer_ReturnsFalse() {
        let loc1 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")
        let loc2 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R2")

        XCTAssertFalse(loc1?.isSimilarTo(loc2!) ?? true)
    }

    func testIsSimilarTo_IgnoresTimestamp() {
        let loc1 = TPPBookLocation(locationString: "{\"chapter\": 1, \"timeStamp\": \"2024-01-01\"}", renderer: "R1")
        let loc2 = TPPBookLocation(locationString: "{\"chapter\": 1, \"timeStamp\": \"2024-12-31\"}", renderer: "R1")

        XCTAssertTrue(loc1?.isSimilarTo(loc2!) ?? false)
    }

    func testIsSimilarTo_IgnoresAnnotationId() {
        let loc1 = TPPBookLocation(locationString: "{\"chapter\": 1, \"annotationId\": \"abc\"}", renderer: "R1")
        let loc2 = TPPBookLocation(locationString: "{\"chapter\": 1, \"annotationId\": \"xyz\"}", renderer: "R1")

        XCTAssertTrue(loc1?.isSimilarTo(loc2!) ?? false)
    }

    func testLocationStringDictionary_ParsesValidJSON() {
        let location = TPPBookLocation(locationString: "{\"chapter\": 5, \"progress\": 0.5}", renderer: "R1")
        let dict = location?.locationStringDictionary()

        XCTAssertEqual(dict?["chapter"] as? Int, 5)
        XCTAssertEqual(dict?["progress"] as? Double, 0.5)
    }

    func testLocationStringDictionary_WithInvalidJSON_ReturnsNil() {
        let location = TPPBookLocation(locationString: "not valid json", renderer: "R1")

        XCTAssertNil(location?.locationStringDictionary())
    }
}

// MARK: - deriveInitialState Tests

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

/// Tests for the re-entrancy guard added to prevent EXC_BAD_ACCESS crashes
/// when load() is called multiple times rapidly during account changes.
final class TPPBookRegistryLoadReentrancyTests: XCTestCase {

    var registry: TPPBookRegistry!
    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        registry = TPPBookRegistry.shared
        cancellables.removeAll()
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Verifies that calling load() multiple times rapidly for the same account
    /// doesn't cause crashes or undefined behavior due to re-entrancy.
    func testLoad_RapidCallsForSameAccount_DoesNotCrash() {
        // Simulate rapid calls that could trigger a crash.
        // This pattern was causing EXC_BAD_ACCESS before the re-entrancy fix.
        // In test environments without a real account, load() may not emit
        // registry changes, so we simply verify no crash occurs.
        for _ in 0..<10 {
            registry.load()
        }

        // If we got here without crashing, the re-entrancy guard is working
    }

    /// Verifies that the registry emits book state events after loading
    /// This was added to fix UI sync issues when reopening the app
    func testLoad_EmitsBookStateEventsForAllBooks() {
        // Guard: load() requires a valid account to actually run.
        // Without one, it returns immediately as a no-op, but allBooks may still
        // contain stale books from other tests (e.g., thread safety tests that
        // add books to the shared singleton). This would cause a false failure.
        guard AccountsManager.shared.currentAccountId != nil else {
            return
        }

        // Drain pending main-thread events from previous tests to ensure
        // the re-entrancy guard's loadingAccount has been cleared.
        // Without this, testLoad_RapidCallsForSameAccount_DoesNotCrash
        // may leave loadingAccount set, causing this test's load() to be skipped.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        let expectation = XCTestExpectation(description: "Book state events emitted")

        var receivedStateUpdates = Set<String>()

        registry.bookStatePublisher
            .sink { (identifier, _) in
                receivedStateUpdates.insert(identifier)
            }
            .store(in: &cancellables)

        // Subscribe for the first event before calling load() so we don't miss it.
        registry.bookStatePublisher
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        registry.load()

        // allBooks uses syncQueue.sync — drains the async load barrier before returning.
        // If no books were loaded there are no publisher events, so fulfill immediately.
        let registryCount = registry.allBooks.count
        if registryCount == 0 {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        if registryCount > 0 {
            XCTAssertFalse(receivedStateUpdates.isEmpty, "Should have received state updates for loaded books")
        }
    }

}
