//
//  AudiobookmarkTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 4/26/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AudiobookmarkTests: XCTestCase {
  
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
    
    XCTAssertEqual(bookmark.time, 2199000)
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual(bookmark.title, "Track 1")
    XCTAssertEqual(bookmark.part, 0)
    XCTAssertEqual(bookmark.chapter, "0")
  }
  
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
    
    XCTAssertEqual(bookmark.time, 2199000)
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual(bookmark.title, "Track 1")
    XCTAssertEqual(bookmark.part, 0)
    XCTAssertEqual(bookmark.chapter, "0")
  }
  
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
    
    XCTAssertEqual(bookmark.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
    XCTAssertEqual(bookmark.readingOrderItemOffsetMilliseconds, 15823)
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
  }
  
  func testEncodeAndDecodeBookmark() throws {
    let locator: [String: Any] = [
      "readingOrderItem": "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0",
      "readingOrderItemOffsetMilliseconds": 15823,
      "@type": "LocatorAudioBookTime",
      "@version": 2
    ]
    let bookmark = AudioBookmark.create(locatorData: locator, timeStamp: "2024-05-28T17:54:51Z", annotationId: "another-annotation-id")!
    
    let data = try JSONEncoder().encode(bookmark)
    let decodedBookmark = try JSONDecoder().decode(AudioBookmark.self, from: data)
    
    XCTAssertEqual(decodedBookmark.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
    XCTAssertEqual(decodedBookmark.readingOrderItemOffsetMilliseconds, 15823)
    XCTAssertEqual(decodedBookmark.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual(decodedBookmark.version, 2)
    XCTAssertEqual(decodedBookmark.lastSavedTimeStamp, "2024-05-28T17:54:51Z")
    XCTAssertEqual(decodedBookmark.annotationId, "another-annotation-id")
  }
}
