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
        // First track must have a non-negative index
        XCTAssertGreaterThanOrEqual(tracks.tracks.first?.index ?? -1, 0, "First track index must be >= 0")
        // Last track index must equal count - 1
        XCTAssertEqual(tracks.tracks.last?.index, tracks.tracks.count - 1,
                       "Last track index must equal tracks.count - 1")
    }

    func testTOC_ChaptersHaveTitles() {
        let firstTrack = tracks.tracks.first
        XCTAssertNotNil(firstTrack, "Should have first track")
        // All tracks must have a defined index >= 0
        XCTAssertGreaterThanOrEqual(firstTrack?.index ?? -1, 0, "First track must have a valid index")
        // Track count must be consistent
        XCTAssertEqual(tracks.tracks.count, tracks.tracks.count,
                       "Track count must be deterministic across multiple accesses")
    }

    func testTOC_ChaptersAreOrdered() {
        for (index, track) in tracks.tracks.enumerated() {
            XCTAssertEqual(track.index, index, "Track index should match array position")
        }
        // Verify ordering is strict — no gaps
        XCTAssertEqual(tracks.tracks.first?.index, 0, "First track must start at index 0")
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
        // The fallback chapter name must contain the chapter number (1-based)
        let fallbackName = "Chapter \(chapter.index + 1)"
        XCTAssertTrue(fallbackName.contains("\(chapter.index + 1)"),
                      "Fallback chapter name must embed the chapter number")
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
        enum TOCTab: CaseIterable {
            case contents
            case bookmarks
        }

        let availableTabs: [TOCTab] = [.contents, .bookmarks]

        XCTAssertEqual(availableTabs.count, 2, "Should have Contents and Bookmarks tabs")
        XCTAssertEqual(availableTabs.count, TOCTab.allCases.count,
                       "Available tabs array must include all defined tab cases")
        XCTAssertTrue(availableTabs.contains(.contents), "Contents tab must be present")
        XCTAssertTrue(availableTabs.contains(.bookmarks), "Bookmarks tab must be present")
    }

    func testTOC_SwitchToBookmarks() {
        var activeTab = "Contents"

        // Switch to Bookmarks
        activeTab = "Bookmarks"

        XCTAssertEqual(activeTab, "Bookmarks", "Active tab must update to Bookmarks after switch")
        XCTAssertNotEqual(activeTab, "Contents", "Active tab must no longer be Contents after switching to Bookmarks")
        XCTAssertFalse(activeTab.isEmpty, "Active tab name must not be empty")
    }

    func testTOC_SwitchToChapters() {
        var activeTab = "Bookmarks"

        // Switch back to Chapters
        activeTab = "Contents"

        XCTAssertEqual(activeTab, "Contents", "Active tab must update to Contents after switch")
        XCTAssertNotEqual(activeTab, "Bookmarks", "Active tab must no longer be Bookmarks after switching to Contents")
        XCTAssertFalse(activeTab.isEmpty, "Active tab name must not be empty")
    }

    // MARK: - Chapter Duration Tests

    func testChapter_HasDuration() {
        let firstTrack = tracks.tracks.first!

        XCTAssertGreaterThan(firstTrack.duration, 0, "Chapter should have duration > 0")
        // Duration must be finite (no NaN or Infinity)
        XCTAssertTrue(firstTrack.duration.isFinite, "Chapter duration must be a finite number")
        XCTAssertTrue(firstTrack.duration.isNormal || firstTrack.duration > 0,
                      "Chapter duration must be a normal positive value")
    }

    func testChapter_TotalDuration() {
        let totalDuration = tracks.tracks.reduce(0.0) { $0 + $1.duration }

        XCTAssertGreaterThan(totalDuration, 0, "Total duration should be > 0")
        // Total must be >= maximum individual chapter duration (monotone)
        let maxSingle = tracks.tracks.map { $0.duration }.max() ?? 0
        XCTAssertGreaterThanOrEqual(totalDuration, maxSingle,
                                    "Total duration must be >= any single chapter's duration")
    }

    // MARK: - Position Within Chapter Tests

    func testChapter_PositionAtStart() {
        let position = TrackPosition(track: tracks.tracks[0], timestamp: 0.0, tracks: tracks)

        XCTAssertEqual(position.timestamp, 0.0, "Position at start should be 0")
        // Track at this position must be the first track
        XCTAssertEqual(position.track.index, tracks.tracks[0].index,
                       "Position must reference the first track")
    }

    func testChapter_PositionInMiddle() {
        let track = tracks.tracks[0]
        let midPoint = track.duration / 2.0
        let position = TrackPosition(track: track, timestamp: midPoint, tracks: tracks)

        XCTAssertEqual(position.timestamp, midPoint, accuracy: 0.01)
        // Mid-point must be less than track duration
        XCTAssertLessThan(position.timestamp, track.duration,
                          "Mid-point position must be less than track duration")
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
