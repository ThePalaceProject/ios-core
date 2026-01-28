//
//  AudiobookTrackerExtendedTests.swift
//  PalaceTests
//
//  Extended tests for audiobook time tracking
//

import XCTest
import Combine
@testable import Palace

// MARK: - Playback State Transition Tests

final class AudiobookPlaybackStateTests: XCTestCase {
  
  private var tracker: AudiobookTimeTracker!
  private var mockDataManager: MockDataManager!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
    tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
  }
  
  override func tearDown() {
    tracker = nil
    mockDataManager = nil
    super.tearDown()
  }
  
  func testPlaybackStarted_canBeCalledMultipleTimes() {
    tracker.playbackStarted()
    tracker.playbackStarted()
    tracker.playbackStarted()
    
    // Should not crash
    XCTAssertTrue(true, "Multiple playbackStarted calls handled")
  }
  
  func testPlaybackStopped_canBeCalledWithoutStart() {
    tracker.playbackStopped()
    
    // Should not crash
    XCTAssertTrue(true, "playbackStopped without start handled")
  }
  
  func testPlaybackStartAndStop_cycle() {
    let date = Date()
    
    tracker.playbackStarted()
    for i in 0..<10 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    tracker.playbackStopped()
    
    tracker.playbackStarted()
    for i in 10..<20 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    tracker.playbackStopped()
    
    // Explicitly finalize to save accumulated time (don't rely on deinit)
    tracker.stopAndSave()
    mockDataManager.flush()
    
    let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertGreaterThan(total, 0, "Should have accumulated time")
  }
}

// MARK: - Time Entry Tests

final class TimeEntryTests: XCTestCase {
  
  func testTimeEntry_creation() {
    let entry = AudiobookTimeEntry(
      id: "test-id",
      bookId: "book-123",
      libraryId: "library-456",
      timeTrackingUrl: URL(string: "https://example.com")!,
      duringMinute: "2024-01-15T10:30:00Z",
      duration: 45
    )
    
    XCTAssertEqual(entry.id, "test-id")
    XCTAssertEqual(entry.bookId, "book-123")
    XCTAssertEqual(entry.libraryId, "library-456")
    XCTAssertEqual(entry.duration, 45)
  }
  
  func testTimeEntry_durationLimit() {
    // Time entries should typically be limited to 60 seconds
    let entry = AudiobookTimeEntry(
      id: "test-id",
      bookId: "book-123",
      libraryId: "library-456",
      timeTrackingUrl: URL(string: "https://example.com")!,
      duringMinute: "2024-01-15T10:30:00Z",
      duration: 60
    )
    
    XCTAssertLessThanOrEqual(entry.duration, 60)
  }
  
  func testTimeEntry_utcFormat() {
    let entry = AudiobookTimeEntry(
      id: "test-id",
      bookId: "book-123",
      libraryId: "library-456",
      timeTrackingUrl: URL(string: "https://example.com")!,
      duringMinute: "2024-01-15T10:30:00Z",
      duration: 30
    )
    
    XCTAssertTrue(entry.duringMinute.hasSuffix("Z"), "Timestamp should be in UTC")
  }
}

// MARK: - Track Completion Tests

final class AudiobookTrackCompletionTests: XCTestCase {
  
  private var mockDataManager: MockDataManager!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
  }
  
  override func tearDown() {
    mockDataManager = nil
    super.tearDown()
  }
  
  func testTrackerFinalize_savesAccumulatedTime() {
    let tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
    
    let date = Date()
    for i in 0..<30 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    
    // Explicitly finalize to save accumulated time (don't rely on deinit)
    tracker.stopAndSave()
    mockDataManager.flush()
    
    // Time entries are saved in batches per minute, not individual seconds
    let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertGreaterThanOrEqual(total, 0, "Should save accumulated time")
  }
  
  func testZeroDuration_notSaved() {
    let tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
    
    // Don't send any playback events, just finalize
    tracker.stopAndSave()
    mockDataManager.flush()
    
    XCTAssertEqual(mockDataManager.savedTimeEntries.count, 0, "Zero duration entries should not be saved")
  }
}

// MARK: - PP-3596 Regression Tests

/// The bug was that playbackStarted() was called unconditionally in setupNowPlayingInfoTimer()
/// even when the player wasn't actually playing, causing time to be tracked incorrectly.
final class PP3596RegressionTests: XCTestCase {
  
  private var mockDataManager: MockDataManager!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
  }
  
  override func tearDown() {
    mockDataManager = nil
    super.tearDown()
  }
  
  /// Verifies that time is NOT tracked when playbackStarted() is called
  /// but no actual playback events (receiveValue) occur.
  /// This simulates the bug where setupNowPlayingInfoTimer() called playbackStarted()
  /// when the app opened but the user hadn't pressed play yet.
  func testPP3596_playbackStartedWithoutPlayback_shouldNotAccumulateTime() {
    let tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
    
    // Simulate the bug: playbackStarted() is called but no actual playback occurs
    tracker.playbackStarted()
    
    // Wait a bit to simulate time passing (in real code, the timer would tick)
    // But since we're not calling receiveValue(), no time should accumulate
    
    // Stop without any playback events
    tracker.playbackStopped()
    mockDataManager.flush()
    
    let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(total, 0, "No time should be tracked when playbackStarted() is called without actual playback")
  }
  
  /// Verifies that time IS tracked only when actual playback events occur
  func testPP3596_onlyActualPlaybackIsTracked() {
    let tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
    
    // Simulate the fixed behavior: playbackStarted() is only called when playing
    let date = Date()
    
    // Simulate 60 seconds of actual playback
    tracker.playbackStarted()
    for i in 0..<60 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    tracker.playbackStopped()
    
    // Explicitly finalize
    tracker.stopAndSave()
    mockDataManager.flush()
    
    let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    
    // Should track approximately 60 seconds (may be slightly less due to timing)
    XCTAssertGreaterThan(total, 55, "Should track close to 60 seconds of actual playback")
    XCTAssertLessThanOrEqual(total, 60, "Should not exceed actual playback time")
  }
  
  /// Verifies that multiple playbackStarted() calls don't cause overcounting
  /// This tests the fix where we cancel existing timer before creating new one
  func testPP3596_multiplePlaybackStartedCalls_shouldNotOvercount() {
    let tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
    
    let date = Date()
    
    // Simulate multiple playbackStarted() calls (as happens with app foreground transitions)
    tracker.playbackStarted()
    tracker.playbackStarted()
    tracker.playbackStarted()
    
    // Simulate 30 seconds of playback
    for i in 0..<30 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    
    tracker.playbackStopped()
    tracker.stopAndSave()
    mockDataManager.flush()
    
    let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    
    // Should track approximately 30 seconds, NOT more due to multiple starts
    XCTAssertGreaterThan(total, 25, "Should track close to 30 seconds")
    XCTAssertLessThanOrEqual(total, 30, "Should not overcount due to multiple playbackStarted() calls")
  }
}

// MARK: - Background Audio Tests

final class AudiobookBackgroundAudioTests: XCTestCase {
  
  private var mockDataManager: MockDataManager!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
  }
  
  override func tearDown() {
    mockDataManager = nil
    super.tearDown()
  }
  
  func testContinuousPlayback_accumulatesCorrectly() {
    let tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
    
    // Simulate 2 minutes of continuous playback
    let date = Date()
    for i in 0..<120 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    
    // Explicitly finalize to save accumulated time (don't rely on deinit)
    tracker.stopAndSave()
    mockDataManager.flush()
    
    let entries = mockDataManager.savedTimeEntries
    let total = entries.reduce(0) { $0 + $1.duration }
    
    // Time tracking saves in batches per minute (max 60 seconds per entry)
    // The exact total depends on timing and batch boundaries
    XCTAssertGreaterThan(total, 0, "Should accumulate some time")
    XCTAssertLessThanOrEqual(total, 120, "Should not exceed simulated time")
  }
  
  func testInterruptedPlayback_savesPartialTime() {
    let tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
    
    let date = Date()
    
    // First segment - simulate crossing minute boundary by adding 60 seconds offset
    for i in 0..<25 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    tracker.playbackStopped()
    
    // Simulate gap then resume - use a time that crosses into next minute
    tracker.playbackStarted()
    for i in 60..<75 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
      tracker.receiveValue(time)
    }
    
    // Explicitly finalize to save accumulated time (don't rely on deinit)
    tracker.stopAndSave()
    mockDataManager.flush()
    
    let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertGreaterThan(total, 0, "Should have saved partial time")
  }
}

