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
    let bookmark = try decoder.decode(AudioBookmark.self, from: earlyBookmarkJSON.data(using: .utf8)!)
    
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.time, 2199000)
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.audiobookID, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.title, "Track 1")
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.part, 0)
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.duration, 3659000)
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.chapter, 0)
    XCTAssertNil((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.startOffset)
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
    let bookmark = try decoder.decode(AudioBookmark.self, from: newerBookmarkJSON.data(using: .utf8)!)
    
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.time, 2199000)
    XCTAssertEqual(bookmark.type.rawValue, "LocatorAudioBookTime")
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.audiobookID, "urn:librarysimplified.org/terms/id/Overdrive ID/faf182e5-2f05-4729-b2cd-139d6bb0b19e")
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.title, "Track 1")
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.part, 0)
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.duration, 3659000)
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.chapter, 0)
    XCTAssertEqual((bookmark.locator as? AudioBookmark.LocatorAudioBookTime1)?.startOffset, 0)
  }
}
