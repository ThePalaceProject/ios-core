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
    let locator = try decoder.decode(AudioBookmark.LocatorAudioBookTime1.self, from: earlyBookmarkJSON.data(using: .utf8)!)
    let bookmark = AudioBookmark(locator: locator)
    
    XCTAssertEqual(locator.time, 2199000)
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual(locator.audiobookID, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
    XCTAssertEqual(locator.title, "Track 1")
    XCTAssertEqual(locator.part, 0)
    XCTAssertEqual(locator.duration, 3659000)
    XCTAssertEqual(locator.chapter, 0)
    XCTAssertNil(locator.startOffset)
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
    let locator = try decoder.decode(AudioBookmark.LocatorAudioBookTime1.self, from: newerBookmarkJSON.data(using: .utf8)!)
    let bookmark = AudioBookmark(locator: locator)
    
    XCTAssertEqual(locator.time, 2199000)
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual(locator.audiobookID, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
    XCTAssertEqual(locator.title, "Track 1")
    XCTAssertEqual(locator.part, 0)
    XCTAssertEqual(locator.duration, 3659000)
    XCTAssertEqual(locator.chapter, 0)
    XCTAssertEqual(locator.startOffset, 0)
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
    let locator = try decoder.decode(AudioBookmark.LocatorAudioBookTime2.self, from: locatorAudioBookTime2JSON.data(using: .utf8)!)
    let bookmark = AudioBookmark(locator: locator)
    
    XCTAssertEqual(locator.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
    XCTAssertEqual(locator.readingOrderItemOffsetMilliseconds, 15823)
    XCTAssertEqual(locator.type, "LocatorAudioBookTime")
    XCTAssertEqual(locator.version, 2)
  }
  
  func testDecodeBookmarkWithAnnotationIdAndTimestamp() throws {
    let bookmarkWithAnnotationIdAndTimestampJSON = """
        {
            "@type": "LocatorAudioBookTime",
            "timeStamp": "2024-05-28T17:54:51Z",
            "annotationId": "some-annotation-id",
            "locator": {
                "readingOrderItem": "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0",
                "readingOrderItemOffsetMilliseconds": 15823,
                "@type": "LocatorAudioBookTime",
                "@version": 2
            }
        }
        """
    
    let decoder = JSONDecoder()
    let bookmark = try decoder.decode(AudioBookmark.self, from: bookmarkWithAnnotationIdAndTimestampJSON.data(using: .utf8)!)
    
    XCTAssertEqual(bookmark.lastSavedTimeStamp, "2024-05-28T17:54:51Z")
    XCTAssertEqual(bookmark.annotationId, "some-annotation-id")
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
    
    let locator = bookmark.locator as? AudioBookmark.LocatorAudioBookTime2
    XCTAssertEqual(locator?.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
    XCTAssertEqual(locator?.readingOrderItemOffsetMilliseconds, 15823)
    XCTAssertEqual(locator?.type, "LocatorAudioBookTime")
    XCTAssertEqual(locator?.version, 2)
  }
  
  func testEncodeAndDecodeBookmark() throws {
    let locator1 = AudioBookmark.LocatorAudioBookTime1(
      title: "Track 1",
      chapter: 0,
      part: 0,
      duration: 3659000,
      startOffset: 0,
      time: 2199000,
      audiobookID: "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e"
    )
    let bookmark1 = AudioBookmark(locator: locator1, timeStamp: "2024-05-28T17:54:51Z", annotationId: "some-annotation-id")
    
    let data1 = try JSONEncoder().encode(bookmark1)
    let decodedBookmark1 = try JSONDecoder().decode(AudioBookmark.self, from: data1)
    
    XCTAssertEqual((decodedBookmark1.locator as? AudioBookmark.LocatorAudioBookTime1)?.time, 2199000)
    XCTAssertEqual(decodedBookmark1.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual((decodedBookmark1.locator as? AudioBookmark.LocatorAudioBookTime1)?.audiobookID, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
    XCTAssertEqual((decodedBookmark1.locator as? AudioBookmark.LocatorAudioBookTime1)?.title, "Track 1")
    XCTAssertEqual((decodedBookmark1.locator as? AudioBookmark.LocatorAudioBookTime1)?.part, 0)
    XCTAssertEqual((decodedBookmark1.locator as? AudioBookmark.LocatorAudioBookTime1)?.duration, 3659000)
    XCTAssertEqual((decodedBookmark1.locator as? AudioBookmark.LocatorAudioBookTime1)?.chapter, 0)
    XCTAssertEqual((decodedBookmark1.locator as? AudioBookmark.LocatorAudioBookTime1)?.startOffset, 0)
    XCTAssertEqual(decodedBookmark1.lastSavedTimeStamp, "2024-05-28T17:54:51Z")
    XCTAssertEqual(decodedBookmark1.annotationId, "some-annotation-id")
    
    let locator2 = AudioBookmark.LocatorAudioBookTime2(
      readingOrderItem: "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0",
      readingOrderItemOffsetMilliseconds: 15823
    )
    let bookmark2 = AudioBookmark(locator: locator2, timeStamp: "2024-05-28T17:54:51Z", annotationId: "another-annotation-id")
    
    let data2 = try JSONEncoder().encode(bookmark2)
    let decodedBookmark2 = try JSONDecoder().decode(AudioBookmark.self, from: data2)
    
    XCTAssertEqual((decodedBookmark2.locator as? AudioBookmark.LocatorAudioBookTime2)?.readingOrderItem, "urn:uuid:ddf56790-60a7-413c-9771-7f7dcef2f565-0")
    XCTAssertEqual((decodedBookmark2.locator as? AudioBookmark.LocatorAudioBookTime2)?.readingOrderItemOffsetMilliseconds, 15823)
    XCTAssertEqual((decodedBookmark2.locator as? AudioBookmark.LocatorAudioBookTime2)?.type, "LocatorAudioBookTime")
    XCTAssertEqual((decodedBookmark2.locator as? AudioBookmark.LocatorAudioBookTime2)?.version, 2)
    XCTAssertEqual(decodedBookmark2.lastSavedTimeStamp, "2024-05-28T17:54:51Z")
    XCTAssertEqual(decodedBookmark2.annotationId, "another-annotation-id")
  }
}
