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
    XCTAssertEqual(bookmark.readingOrderItem, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
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
    XCTAssertEqual(bookmark.readingOrderItem, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
    XCTAssertEqual(bookmark.title, "Track 1")
    XCTAssertEqual(bookmark.part, 0)
    XCTAssertEqual(bookmark.chapter, "0")
    XCTAssertEqual(bookmark.readingOrderItemOffsetMilliseconds, 0)
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
    let locator1: [String: Any] = [
      "title": "Track 1",
      "chapter": 0,
      "part": 0,
      "duration": 3659000,
      "startOffset": 0,
      "time": 2199000,
      "audiobookID": "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e",
      "@type": "LocatorAudioBookTime"
    ]
    let bookmark1 = AudioBookmark.create(locatorData: locator1, timeStamp: "2024-05-28T17:54:51Z", annotationId: "some-annotation-id")!
    
    let data1 = try JSONEncoder().encode(bookmark1)
    let decodedBookmark1 = try JSONDecoder().decode(AudioBookmark.self, from: data1)
    
    XCTAssertEqual(decodedBookmark1.time, 2199000)
    XCTAssertEqual(decodedBookmark1.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual(decodedBookmark1.readingOrderItem, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
    XCTAssertEqual(decodedBookmark1.title, "Track 1")
    XCTAssertEqual(decodedBookmark1.part, 0)
    XCTAssertEqual(decodedBookmark1.chapter, "0")
    XCTAssertEqual(decodedBookmark1.lastSavedTimeStamp, "2024-05-28T17:54:51Z")
    XCTAssertEqual(decodedBookmark1.annotationId, "some-annotation-id")
    
    let locator2: [String: Any] = [
      "readingOrderItem": "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0",
      "readingOrderItemOffsetMilliseconds": 15823,
      "@type": "LocatorAudioBookTime",
      "@version": 2
    ]
    let bookmark2 = AudioBookmark.create(locatorData: locator2, timeStamp: "2024-05-28T17:54:51Z", annotationId: "another-annotation-id")!
    
    let data2 = try JSONEncoder().encode(bookmark2)
    let decodedBookmark2 = try JSONDecoder().decode(AudioBookmark.self, from: data2)
    
    XCTAssertEqual(decodedBookmark2.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
    XCTAssertEqual(decodedBookmark2.readingOrderItemOffsetMilliseconds, 15823)
    XCTAssertEqual(decodedBookmark2.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual(decodedBookmark2.version, 2)
    XCTAssertEqual(decodedBookmark2.lastSavedTimeStamp, "2024-05-28T17:54:51Z")
    XCTAssertEqual(decodedBookmark2.annotationId, "another-annotation-id")
  }
}
