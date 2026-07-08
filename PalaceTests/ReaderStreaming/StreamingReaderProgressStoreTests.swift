//
//  StreamingReaderProgressStoreTests.swift
//  PalaceTests
//
//  Round-trip and prefix-scoping coverage for the UserDefaults-backed
//  streaming-reader progress store. Uses an isolated `UserDefaults(suiteName:)`
//  so test runs don't pollute the host's standard defaults.
//

import CoreGraphics
import XCTest
@testable import Palace

final class StreamingReaderProgressStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "palace.streamingReader.tests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite for test")
            return
        }
        defaults = suite
    }

    override func tearDown() {
        if let suite = defaults, let name = suiteName {
            suite.removePersistentDomain(forName: name)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Round-trip

    func testStreamingReaderProgressStore_writeThenRead_returnsExactScrollOffset() {
        let store = StreamingReaderProgressStore(userDefaults: defaults)
        let bookID = "book-123"

        store.save(scrollOffset: 123.5, fragment: "#section-3", forBookID: bookID)

        guard let restored = store.read(forBookID: bookID) else {
            XCTFail("Expected restored progress for bookID \(bookID)")
            return
        }
        XCTAssertEqual(restored.scrollOffset, 123.5)
        XCTAssertEqual(restored.fragment, "#section-3")
    }

    func testStreamingReaderProgressStore_writeThenRead_nilFragmentRoundTrips() {
        let store = StreamingReaderProgressStore(userDefaults: defaults)

        store.save(scrollOffset: 0, fragment: nil, forBookID: "book-xyz")

        let restored = store.read(forBookID: "book-xyz")
        XCTAssertEqual(restored?.scrollOffset, 0)
        XCTAssertNil(restored?.fragment)
    }

    // MARK: - Prefix scoping

    func testStreamingReaderProgressStore_read_returnsNilForDifferentBookID() {
        let store = StreamingReaderProgressStore(userDefaults: defaults)

        store.save(scrollOffset: 250, fragment: nil, forBookID: "bookA")

        XCTAssertNotNil(store.read(forBookID: "bookA"))
        XCTAssertNil(store.read(forBookID: "bookB"))
    }

    func testStreamingReaderProgressStore_save_doesNotOverwriteOtherBooks() {
        let store = StreamingReaderProgressStore(userDefaults: defaults)

        store.save(scrollOffset: 100, fragment: nil, forBookID: "bookA")
        store.save(scrollOffset: 999, fragment: "#end", forBookID: "bookB")

        XCTAssertEqual(store.read(forBookID: "bookA")?.scrollOffset, 100)
        XCTAssertEqual(store.read(forBookID: "bookB")?.scrollOffset, 999)
        XCTAssertEqual(store.read(forBookID: "bookB")?.fragment, "#end")
    }

    // MARK: - Malformed payload fallback

    func testStreamingReaderProgressStore_read_malformedJSON_returnsNil() {
        let store = StreamingReaderProgressStore(userDefaults: defaults)
        let bookID = "book-malformed"

        // Write garbage to the same key the store uses, bypassing the encoder.
        defaults.set("this is not JSON {", forKey: "palace.streamingReader.progress.\(bookID)")

        XCTAssertNil(store.read(forBookID: bookID))
    }

    func testStreamingReaderProgressStore_read_unknownBookID_returnsNil() {
        let store = StreamingReaderProgressStore(userDefaults: defaults)

        XCTAssertNil(store.read(forBookID: "never-saved"))
    }

    // MARK: - Key prefix sanity

    func testStreamingReaderProgressStore_save_usesPalaceStreamingReaderPrefix() {
        let store = StreamingReaderProgressStore(userDefaults: defaults)
        let bookID = "book-prefix"

        store.save(scrollOffset: 42, fragment: nil, forBookID: bookID)

        // The key under which the payload is stored must be prefixed so it
        // can't collide with arbitrary UserDefaults keys elsewhere in the app.
        let expectedKey = "palace.streamingReader.progress.\(bookID)"
        XCTAssertNotNil(defaults.object(forKey: expectedKey))
    }
}
