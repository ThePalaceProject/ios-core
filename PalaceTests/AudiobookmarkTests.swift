//
//  AudiobookmarkTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 4/26/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookmarkTests: XCTestCase {

    // Verifies that the legacy v1 format (time/chapter/part) is parsed into the
    // correct fields and that the resulting bookmark's uniqueIdentifier is
    // derived from those fields — exercising the identifier computation path.
    func testDecodeEarlyBookmark() throws {
        let earlyBookmarkJSON = """
        {
            "@type": "LocatorAudioBookTime",
            "time": 2199000,
            "audiobookID": "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e",
            "title": "Track 1",
            "part": 0,
            "duration": 3659000,
            "chapter": 0
        }
        """

        let decoder = JSONDecoder()
        let locatorDict = try decoder.decode([String: AnyCodable].self, from: earlyBookmarkJSON.data(using: .utf8)!)
        let locator = locatorDict.mapValues { $0.value }
        let bookmark = AudioBookmark.create(locatorData: locator)!

        // Act: exercise the computed uniqueIdentifier to verify all three
        // legacy fields were wired up correctly.
        let uniqueId = bookmark.uniqueIdentifier

        XCTAssertEqual(bookmark.time, 2199000)
        XCTAssertEqual(bookmark.title, "Track 1")
        XCTAssertEqual(bookmark.part, 0)
        XCTAssertEqual(bookmark.chapter, "0")
        // uniqueIdentifier for v1 format is "<chapter>-<part>-<time>"
        XCTAssertEqual(uniqueId, "0-0-2199000", "uniqueIdentifier should encode chapter, part, and time")
    }

    // Verifies that the v1 + startOffset format still populates legacy fields
    // and that isSimilar correctly treats two bookmarks at the same position
    // as similar (important for duplicate-prevention logic).
    func testDecodeNewerBookmark() throws {
        let newerBookmarkJSON = """
        {
            "@type": "LocatorAudioBookTime",
            "time": 2199000,
            "audiobookID": "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e",
            "title": "Track 1",
            "part": 0,
            "duration": 3659000,
            "chapter": 0,
            "startOffset": 0
        }
        """

        let decoder = JSONDecoder()
        let locatorDict = try decoder.decode([String: AnyCodable].self, from: newerBookmarkJSON.data(using: .utf8)!)
        let locator = locatorDict.mapValues { $0.value }
        let bookmark = AudioBookmark.create(locatorData: locator)!

        // Act: create a second bookmark at the same position and check similarity.
        let duplicate = AudioBookmark.create(locatorData: locator)!
        let isSimilar = bookmark.isSimilar(to: duplicate)

        XCTAssertEqual(bookmark.time, 2199000)
        XCTAssertEqual(bookmark.title, "Track 1")
        XCTAssertTrue(isSimilar, "Two bookmarks decoded from identical locator data should be similar")
    }

    // Verifies v2 format parsing and that toTPPBookLocation() produces a
    // non-nil location with the correct renderer — exercising the serialization
    // path that is used when persisting bookmarks to the book registry.
    func testDecodeLocatorAudioBookTime2() throws {
        let locatorAudioBookTime2JSON = """
        {
            "readingOrderItem": "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0",
            "readingOrderItemOffsetMilliseconds": 15823,
            "@type": "LocatorAudioBookTime",
            "@version": 2
        }
        """

        let decoder = JSONDecoder()
        let locatorDict = try decoder.decode([String: AnyCodable].self, from: locatorAudioBookTime2JSON.data(using: .utf8)!)
        let locator = locatorDict.mapValues { $0.value }
        let bookmark = AudioBookmark.create(locatorData: locator)!

        // Act: convert to TPPBookLocation — this exercises toData() + string encoding.
        let location = bookmark.toTPPBookLocation()

        XCTAssertEqual(bookmark.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
        XCTAssertEqual(bookmark.readingOrderItemOffsetMilliseconds, 15823)
        XCTAssertNotNil(location, "toTPPBookLocation() should succeed for a valid v2 bookmark")
        XCTAssertEqual(location?.renderer, "PalaceAudiobookToolkit")
    }

    // Verifies full encode/decode round-trip and that isUnsynced returns false
    // for a bookmark that carries a non-empty annotationId (the field that
    // signals whether the server has acknowledged the annotation).
    func testEncodeAndDecodeBookmark() throws {
        let locator: [String: Any] = [
            "readingOrderItem": "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0",
            "readingOrderItemOffsetMilliseconds": 15823,
            "@type": "LocatorAudioBookTime",
            "@version": 2
        ]
        let bookmark = AudioBookmark.create(locatorData: locator, timeStamp: "2024-05-28T17:54:51Z", annotationId: "another-annotation-id")!

        // Act: encode then decode to exercise the full Codable round-trip.
        let data = try JSONEncoder().encode(bookmark)
        let decodedBookmark = try JSONDecoder().decode(AudioBookmark.self, from: data)

        XCTAssertEqual(decodedBookmark.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
        XCTAssertEqual(decodedBookmark.readingOrderItemOffsetMilliseconds, 15823)
        XCTAssertEqual(decodedBookmark.version, 2)
        XCTAssertEqual(decodedBookmark.lastSavedTimeStamp, "2024-05-28T17:54:51Z")
        XCTAssertEqual(decodedBookmark.annotationId, "another-annotation-id")
        // isUnsynced is false when annotationId is non-empty — the round-trip
        // must preserve annotationId for this invariant to hold.
        XCTAssertFalse(decodedBookmark.isUnsynced, "Bookmark with annotationId should not be marked as unsynced")
    }
}
