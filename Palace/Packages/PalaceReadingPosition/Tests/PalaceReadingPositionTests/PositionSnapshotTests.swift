//
//  PositionSnapshotTests.swift
//  PalaceReadingPositionTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceReadingPosition

final class PositionSnapshotTests: XCTestCase {

    func testEquatable_sameFields_returnsTrue() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let a = PositionSnapshot(bookID: "b1", format: .epubLocator, payload: Data("p".utf8), timestamp: timestamp, device: "d1")
        let b = PositionSnapshot(bookID: "b1", format: .epubLocator, payload: Data("p".utf8), timestamp: timestamp, device: "d1")
        XCTAssertEqual(a, b)
    }

    func testEquatable_differentTimestamp_returnsFalse() {
        let payload = Data("p".utf8)
        let a = PositionSnapshot(bookID: "b1", format: .epubLocator, payload: payload, timestamp: Date(timeIntervalSince1970: 1_000), device: "d1")
        let b = PositionSnapshot(bookID: "b1", format: .epubLocator, payload: payload, timestamp: Date(timeIntervalSince1970: 1_001), device: "d1")
        XCTAssertNotEqual(a, b)
    }

    func testCodable_audiobookFormat_roundtrips() throws {
        let original = PositionSnapshot(
            bookID: "ab-1",
            format: .audiobook,
            payload: Data("audiobook-locator".utf8),
            timestamp: Date(timeIntervalSince1970: 1_000),
            device: "ipad"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PositionSnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.format, .audiobook)
    }

    func testCodable_epubLocatorFormat_roundtrips() throws {
        let original = PositionSnapshot(
            bookID: "ep-1",
            format: .epubLocator,
            payload: Data("readium-locator".utf8),
            timestamp: Date(timeIntervalSince1970: 2_000),
            device: "iphone"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PositionSnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.format, .epubLocator)
    }

    func testCodable_pdfPageFormat_roundtrips() throws {
        let original = PositionSnapshot(
            bookID: "pdf-1",
            format: .pdfPage,
            payload: Data("{\"page\":42}".utf8),
            timestamp: Date(timeIntervalSince1970: 3_000),
            device: "mac"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PositionSnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.format, .pdfPage)
    }

    // Bridging extension coverage

    func testInitFromReadingPosition_audiobook_carriesFieldsThroughPayload() throws {
        let pos = ReadingPosition.audiobook(
            bookID: "ab",
            chapterIndex: 3,
            timeOffset: 42,
            overallProgress: 0.5,
            deviceID: "dev"
        )
        let snap = try PositionSnapshot(from: pos)
        XCTAssertEqual(snap.bookID, "ab")
        XCTAssertEqual(snap.format, .audiobook)
        XCTAssertEqual(snap.device, "dev")
        XCTAssertEqual(snap.timestamp, pos.timestamp)

        let roundtripped = try snap.asReadingPosition()
        XCTAssertEqual(roundtripped, pos)
    }
}
