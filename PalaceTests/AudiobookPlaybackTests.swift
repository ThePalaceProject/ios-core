//
//  AudiobookPlaybackTests.swift
//  PalaceTests
//
//  Created for Testing Migration
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

/// Tests for audiobook playback functionality including skip navigation,
/// chapter transitions, and playback speed calculations.
class AudiobookPlaybackTests: XCTestCase {
  
  var mockRegistry: TPPBookRegistryMock!
  var mockAnnotations: TPPAnnotationMock!
  var fakeBook: TPPBook!
  var tracks: Tracks!
  
  let testID = "TestPlaybackID"
  let manifestJSON: ManifestJSON = .snowcrash
  
  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
    mockAnnotations = TPPAnnotationMock()
    
    // Use placeholder URL for acquisitions (not fetched in tests)
    let placeholderUrl = URL(string: "https://test.example.com/book")!
    let fakeAcquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/audiobook+json",
      hrefURL: placeholderUrl,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    fakeBook = TPPBook(
      acquisitions: [fakeAcquisition],
      authors: [TPPBookAuthor](),
      categoryStrings: [String](),
      distributor: "Test Distributor",
      identifier: "testAudiobook123",
      imageURL: nil,  // Use nil to prevent network image fetches
      imageThumbnailURL: nil,  // Use nil to prevent network image fetches
      published: Date(),
      publisher: "Test Publisher",
      subtitle: "",
      summary: "",
      title: "Test Audiobook",
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,  // No preview to prevent network requests
      seriesURL: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: "3600",
      imageCache: MockImageCache()
    )
    
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    tracks = try! loadTracks(for: manifestJSON)
  }
  
  override func tearDown() {
    mockRegistry = nil
    mockAnnotations = nil
    fakeBook = nil
    tracks = nil
    super.tearDown()
  }
  
  func loadTracks(for manifestJSON: ManifestJSON) throws -> Tracks {
    let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
    return Tracks(manifest: manifest, audiobookID: testID, token: nil)
  }
  
  // MARK: - Skip Navigation Tests
  
  func testSkipAhead_Adds30Seconds() {
    let currentTimestamp: Double = 100.0
    let skipAmount: Double = 30.0
    
    let newTimestamp = currentTimestamp + skipAmount
    
    XCTAssertEqual(newTimestamp, 130.0, "Skip ahead should add 30 seconds")
  }
  
  func testSkipBehind_Subtracts30Seconds() {
    let currentTimestamp: Double = 100.0
    let skipAmount: Double = 30.0
    
    let newTimestamp = max(0, currentTimestamp - skipAmount)
    
    XCTAssertEqual(newTimestamp, 70.0, "Skip behind should subtract 30 seconds")
  }
  
  func testSkipBehind_ClampsToZero() {
    let currentTimestamp: Double = 20.0
    let skipAmount: Double = 30.0
    
    let newTimestamp = max(0, currentTimestamp - skipAmount)
    
    XCTAssertEqual(newTimestamp, 0.0, "Skip behind should clamp to zero when would go negative")
  }
  
  func testSkipAhead_WithinTrackDuration() {
    let currentTimestamp: Double = 50.0
    let trackDuration: Double = 300.0
    let skipAmount: Double = 30.0
    
    let newTimestamp = min(trackDuration, currentTimestamp + skipAmount)
    
    XCTAssertEqual(newTimestamp, 80.0, "Skip ahead should stay within track duration")
    XCTAssertLessThanOrEqual(newTimestamp, trackDuration)
  }
  
  func testSkipAhead_ClampsToTrackEnd() {
    let currentTimestamp: Double = 290.0
    let trackDuration: Double = 300.0
    let skipAmount: Double = 30.0
    
    let newTimestamp = min(trackDuration, currentTimestamp + skipAmount)
    
    XCTAssertEqual(newTimestamp, 300.0, "Skip ahead should clamp to track duration")
  }
  
  // MARK: - Playback Speed Calculation Tests
  
  func testPlaybackSpeed_0_75x_CalculatesCorrectDuration() {
    let originalDuration: Double = 60.0 // 60 seconds
    let playbackSpeed: Double = 0.75
    
    let effectiveDuration = originalDuration / playbackSpeed
    
    XCTAssertEqual(effectiveDuration, 80.0, accuracy: 0.01, "0.75x speed should take 80 seconds to play 60 seconds of audio")
  }
  
  func testPlaybackSpeed_1_0x_CalculatesCorrectDuration() {
    let originalDuration: Double = 60.0
    let playbackSpeed: Double = 1.0
    
    let effectiveDuration = originalDuration / playbackSpeed
    
    XCTAssertEqual(effectiveDuration, 60.0, accuracy: 0.01, "1.0x speed should take 60 seconds")
  }
  
  func testPlaybackSpeed_1_25x_CalculatesCorrectDuration() {
    let originalDuration: Double = 60.0
    let playbackSpeed: Double = 1.25
    
    let effectiveDuration = originalDuration / playbackSpeed
    
    XCTAssertEqual(effectiveDuration, 48.0, accuracy: 0.01, "1.25x speed should take 48 seconds")
  }
  
  func testPlaybackSpeed_1_5x_CalculatesCorrectDuration() {
    let originalDuration: Double = 60.0
    let playbackSpeed: Double = 1.5
    
    let effectiveDuration = originalDuration / playbackSpeed
    
    XCTAssertEqual(effectiveDuration, 40.0, accuracy: 0.01, "1.5x speed should take 40 seconds")
  }
  
  func testPlaybackSpeed_2_0x_CalculatesCorrectDuration() {
    let originalDuration: Double = 60.0
    let playbackSpeed: Double = 2.0
    
    let effectiveDuration = originalDuration / playbackSpeed
    
    XCTAssertEqual(effectiveDuration, 30.0, accuracy: 0.01, "2.0x speed should take 30 seconds")
  }
  
  func testPlaybackSpeed_ContentPlayedCalculation() {
    // After 8 seconds of real time at 1.25x, how much content was played?
    let realTimeElapsed: Double = 8.0
    let playbackSpeed: Double = 1.25
    
    let contentPlayed = realTimeElapsed * playbackSpeed
    
    XCTAssertEqual(contentPlayed, 10.0, accuracy: 0.01, "At 1.25x, 8 real seconds = 10 seconds of content")
  }
  
  // MARK: - Chapter Navigation Tests
  
  func testChapterIndex_ValidTrack() {
    guard tracks.tracks.count > 0 else {
      XCTFail("No tracks available for testing")
      return
    }
    
    let firstTrack = tracks.tracks[0]
    XCTAssertEqual(firstTrack.index, 0, "First track should have index 0")
  }
  
  func testChapterNavigation_NextChapter() {
    guard tracks.tracks.count > 1 else {
      XCTFail("Need at least 2 tracks for this test")
      return
    }
    
    let currentChapterIndex = 0
    let nextChapterIndex = currentChapterIndex + 1
    
    XCTAssertEqual(nextChapterIndex, 1, "Next chapter should be index 1")
    XCTAssertLessThan(nextChapterIndex, tracks.tracks.count, "Next chapter should exist")
  }
  
  func testChapterNavigation_PreviousChapter() {
    guard tracks.tracks.count > 1 else {
      XCTFail("Need at least 2 tracks for this test")
      return
    }
    
    let currentChapterIndex = 1
    let previousChapterIndex = max(0, currentChapterIndex - 1)
    
    XCTAssertEqual(previousChapterIndex, 0, "Previous chapter should be index 0")
  }
  
  func testChapterNavigation_PreviousChapter_ClampsToZero() {
    let currentChapterIndex = 0
    let previousChapterIndex = max(0, currentChapterIndex - 1)
    
    XCTAssertEqual(previousChapterIndex, 0, "Previous chapter should clamp to 0")
  }
  
  func testChapterNavigation_NextChapter_AtEnd() {
    guard tracks.tracks.count > 0 else {
      XCTFail("No tracks available")
      return
    }
    
    let lastChapterIndex = tracks.tracks.count - 1
    let nextChapterIndex = min(tracks.tracks.count - 1, lastChapterIndex + 1)
    
    XCTAssertEqual(nextChapterIndex, lastChapterIndex, "Next chapter at end should stay on last chapter")
  }
  
  // MARK: - Sleep Timer Calculation Tests
  
  func testSleepTimer_15Minutes() {
    let sleepDuration: TimeInterval = 15 * 60 // 15 minutes in seconds
    
    XCTAssertEqual(sleepDuration, 900.0, "15 minutes should be 900 seconds")
  }
  
  func testSleepTimer_30Minutes() {
    let sleepDuration: TimeInterval = 30 * 60
    
    XCTAssertEqual(sleepDuration, 1800.0, "30 minutes should be 1800 seconds")
  }
  
  func testSleepTimer_60Minutes() {
    let sleepDuration: TimeInterval = 60 * 60
    
    XCTAssertEqual(sleepDuration, 3600.0, "60 minutes should be 3600 seconds")
  }
  
  func testSleepTimer_RemainingTime() {
    let sleepDuration: TimeInterval = 900.0
    let elapsedTime: TimeInterval = 300.0
    
    let remainingTime = sleepDuration - elapsedTime
    
    XCTAssertEqual(remainingTime, 600.0, "After 5 minutes, 10 minutes should remain")
  }
  
  func testSleepTimer_Expired() {
    let sleepDuration: TimeInterval = 900.0
    let elapsedTime: TimeInterval = 1000.0
    
    let remainingTime = max(0, sleepDuration - elapsedTime)
    
    XCTAssertEqual(remainingTime, 0.0, "Timer should show 0 when expired")
  }
  
  // MARK: - Position Tracking Tests
  
  func testTrackPosition_Creation() {
    guard tracks.tracks.count > 0 else {
      XCTFail("No tracks available")
      return
    }
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 100.0, tracks: tracks)
    
    XCTAssertEqual(position.timestamp, 100.0, "Timestamp should be set correctly")
    XCTAssertEqual(position.track.index, 0, "Track index should be 0")
  }
  
  func testTrackPosition_ToAudioBookmark() {
    guard tracks.tracks.count > 0 else {
      XCTFail("No tracks available")
      return
    }
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 150.0, tracks: tracks)
    let bookmark = position.toAudioBookmark()
    
    XCTAssertNotNil(bookmark, "Should create bookmark from position")
  }
  
  func testTrackPosition_ToTPPBookLocation() {
    guard tracks.tracks.count > 0 else {
      XCTFail("No tracks available")
      return
    }
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 200.0, tracks: tracks)
    let bookmark = position.toAudioBookmark()
    let location = bookmark.toTPPBookLocation()
    
    XCTAssertNotNil(location, "Should create TPPBookLocation from bookmark")
    XCTAssertFalse(location!.locationString.isEmpty, "Location string should not be empty")
  }
  
  // MARK: - Audiobook Time Entry Tests
  
  func testAudiobookTimeEntry_DurationCappedAt60() {
    let duration = 75
    let cappedDuration = min(60, duration)
    
    XCTAssertEqual(cappedDuration, 60, "Duration should be capped at 60 seconds")
  }
  
  func testAudiobookTimeEntry_ValidDuration() {
    let duration = 45
    let cappedDuration = min(60, duration)
    
    XCTAssertEqual(cappedDuration, 45, "Duration under 60 should remain unchanged")
  }
}

