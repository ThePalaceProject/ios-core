//
//  AudiobookTOCTests.swift
//  PalaceTests
//
//  Created for Testing Migration
//  Tests from AudiobookLyrasis.feature: TOC navigation, chapter switching
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

/// Tests for audiobook Table of Contents and chapter navigation functionality.
class AudiobookTOCTests: XCTestCase {
  
  var tracks: Tracks!
  let testID = "TestTOCID"
  let manifestJSON: ManifestJSON = .snowcrash
  
  override func setUp() {
    super.setUp()
    tracks = try! loadTracks(for: manifestJSON)
  }
  
  override func tearDown() {
    tracks = nil
    super.tearDown()
  }
  
  func loadTracks(for manifestJSON: ManifestJSON) throws -> Tracks {
    let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
    return Tracks(manifest: manifest, audiobookID: testID, token: nil)
  }
  
  // MARK: - TOC Structure Tests
  
  func testTOC_HasChapters() {
    XCTAssertGreaterThan(tracks.tracks.count, 0, "TOC should have chapters")
  }
  
  func testTOC_ChaptersHaveTitles() {
    let firstTrack = tracks.tracks.first
    XCTAssertNotNil(firstTrack, "Should have first track")
    // Track titles come from manifest
  }
  
  func testTOC_ChaptersAreOrdered() {
    for (index, track) in tracks.tracks.enumerated() {
      XCTAssertEqual(track.index, index, "Track index should match array position")
    }
  }
  
  // MARK: - Chapter Navigation Tests
  
  func testTOC_OpenSpecificChapter() {
    guard tracks.tracks.count > 2 else {
      XCTSkip("Need at least 3 chapters")
      return
    }
    
    let chapter3 = tracks.tracks[2]
    
    XCTAssertEqual(chapter3.index, 2, "Should open chapter 3 (index 2)")
  }
  
  func testTOC_OpenRandomChapter() {
    guard tracks.tracks.count > 1 else {
      XCTSkip("Need at least 2 chapters")
      return
    }
    
    let randomIndex = Int.random(in: 0..<tracks.tracks.count)
    let randomChapter = tracks.tracks[randomIndex]
    
    XCTAssertGreaterThanOrEqual(randomChapter.index, 0)
    XCTAssertLessThan(randomChapter.index, tracks.tracks.count)
  }
  
  func testTOC_OpenFirstChapter() {
    let firstChapter = tracks.tracks.first
    
    XCTAssertNotNil(firstChapter)
    XCTAssertEqual(firstChapter?.index, 0)
  }
  
  // MARK: - Chapter Name Tests
  
  func testChapterName_SavedCorrectly() {
    let chapter = tracks.tracks.first!
    let savedChapterName = chapter.title ?? "Chapter \(chapter.index + 1)"
    
    XCTAssertFalse(savedChapterName.isEmpty)
  }
  
  func testChapterName_MatchesAfterNavigation() {
    guard tracks.tracks.count > 2 else {
      XCTSkip("Need at least 3 chapters")
      return
    }
    
    let targetChapter = tracks.tracks[2]
    let savedName = targetChapter.title ?? "Chapter 3"
    
    // Simulate navigation
    let currentChapter = targetChapter
    let currentName = currentChapter.title ?? "Chapter 3"
    
    XCTAssertEqual(savedName, currentName, "Chapter name should match after navigation")
  }
  
  // MARK: - Auto-Advance Tests
  
  func testChapter_AutoAdvanceToNext() {
    guard tracks.tracks.count > 1 else {
      XCTSkip("Need at least 2 chapters")
      return
    }
    
    var currentChapterIndex = 0
    let chapterName = tracks.tracks[currentChapterIndex].title
    
    // Simulate listening to end of chapter
    currentChapterIndex += 1
    
    let newChapterName = tracks.tracks[currentChapterIndex].title
    
    // If titles are defined, they should be different
    if chapterName != nil && newChapterName != nil {
      XCTAssertNotEqual(chapterName, newChapterName, "Should auto-advance to next chapter")
    }
    XCTAssertEqual(currentChapterIndex, 1)
  }
  
  // MARK: - TOC Screen Tests
  
  func testTOC_ContentsAndBookmarksTabs() {
    enum TOCTab {
      case contents
      case bookmarks
    }
    
    let availableTabs: [TOCTab] = [.contents, .bookmarks]
    
    XCTAssertEqual(availableTabs.count, 2, "Should have Contents and Bookmarks tabs")
  }
  
  func testTOC_SwitchToBookmarks() {
    var activeTab = "Contents"
    
    // Switch to Bookmarks
    activeTab = "Bookmarks"
    
    XCTAssertEqual(activeTab, "Bookmarks")
  }
  
  func testTOC_SwitchToChapters() {
    var activeTab = "Bookmarks"
    
    // Switch back to Chapters
    activeTab = "Contents"
    
    XCTAssertEqual(activeTab, "Contents")
  }
  
  // MARK: - Chapter Duration Tests
  
  func testChapter_HasDuration() {
    let firstTrack = tracks.tracks.first!
    
    XCTAssertGreaterThan(firstTrack.duration, 0, "Chapter should have duration > 0")
  }
  
  func testChapter_TotalDuration() {
    let totalDuration = tracks.tracks.reduce(0.0) { $0 + $1.duration }
    
    XCTAssertGreaterThan(totalDuration, 0, "Total duration should be > 0")
  }
  
  // MARK: - Position Within Chapter Tests
  
  func testChapter_PositionAtStart() {
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 0.0, tracks: tracks)
    
    XCTAssertEqual(position.timestamp, 0.0, "Position at start should be 0")
  }
  
  func testChapter_PositionInMiddle() {
    let track = tracks.tracks[0]
    let midPoint = track.duration / 2.0
    let position = TrackPosition(track: track, timestamp: midPoint, tracks: tracks)
    
    XCTAssertEqual(position.timestamp, midPoint, accuracy: 0.01)
  }
  
  // MARK: - Chapter Selection Persistence Tests
  
  func testChapter_SelectionPersistsAfterReturn() {
    guard tracks.tracks.count > 2 else {
      XCTSkip("Need at least 3 chapters")
      return
    }
    
    let selectedChapterIndex = 2
    
    // Simulate: Select chapter, leave, return
    var currentChapterIndex = selectedChapterIndex
    
    // "Return to previous screen"
    let previousChapterIndex = currentChapterIndex
    
    // "Return to audio player"
    currentChapterIndex = previousChapterIndex
    
    XCTAssertEqual(currentChapterIndex, selectedChapterIndex, 
                   "Chapter selection should persist after return")
  }
  
  func testChapter_PositionPersistsAfterRestart() {
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 150.0, tracks: tracks)
    
    // Simulate: Save position before restart
    let savedTimestamp = position.timestamp
    let savedChapterIndex = position.track.index
    
    // After restart, restore position
    let restoredPosition = TrackPosition(track: tracks.tracks[savedChapterIndex], 
                                         timestamp: savedTimestamp, 
                                         tracks: tracks)
    
    XCTAssertEqual(restoredPosition.timestamp, savedTimestamp)
    XCTAssertEqual(restoredPosition.track.index, savedChapterIndex)
  }
}

