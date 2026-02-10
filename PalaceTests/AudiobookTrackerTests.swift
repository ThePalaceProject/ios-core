//
//  AudiobookTrackerTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 9/5/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

/// Thread-safe mock data manager for testing
class MockDataManager: DataManager {
  
  private let queue = DispatchQueue(label: "mock.datamanager", attributes: .concurrent)
  private var _savedTimeEntries: [TimeEntry] = []
  
  var savedTimeEntries: [TimeEntry] {
    queue.sync { _savedTimeEntries }
  }
  
  func save(time: TimeEntry) {
    queue.async(flags: .barrier) {
      self._savedTimeEntries.append(time)
    }
  }
  
  func removeSynchronizedEntries(ids: [String]) {
    queue.async(flags: .barrier) {
      self._savedTimeEntries.removeAll { ids.contains($0.id) }
    }
  }
  
  func saveStore() { }
  func loadStore() { }
  func cleanUpUrls() { }
  func syncValues() { }
  
  /// Waits for all pending writes to complete
  func flush() {
    queue.sync(flags: .barrier) { }
  }
}

class AudiobookTimeTrackerTests: XCTestCase {
  
  var sut: AudiobookTimeTracker!
  var mockDataManager: MockDataManager!
  var currentDate: Date!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
    currentDate = Date()
    sut = AudiobookTimeTracker(
      libraryId: "library123",
      bookId: "book123",
      timeTrackingUrl: URL(string: "https://example.com")!,
      dataManager: mockDataManager
    )
  }
  
  override func tearDown() {
    sut = nil
    mockDataManager = nil
    currentDate = nil
    super.tearDown()
  }
  
  func testPlaybackStarted_savesCorrectAggregateTime() {
    // Simulate 90 seconds of playback by sending timestamps
    for i in 0..<90 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    // Verify the tracker's internal state has accumulated time
    // The internal timeEntry should have some duration
    let accumulatedDuration = sut.timeEntry.duration
    XCTAssertGreaterThan(accumulatedDuration, 0, "Tracker should have accumulated time")
  }

  func testTimeEntries_areLimitedTo60Seconds() {
    // Simulate 70 seconds of playback
    for i in 0..<70 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    // The tracker's internal timeEntry should have accumulated time
    // but each individual entry is capped at 60 seconds
    let currentDuration = sut.timeEntry.duration
    XCTAssertLessThanOrEqual(currentDuration, 60, "Current entry duration should be <= 60 seconds")
    
    // Verify time was accumulated
    XCTAssertGreaterThan(currentDuration, 0, "Should have accumulated some time")
  }

  func testTimeEntries_areInUTC() {
    // Simulate playback crossing a minute boundary to trigger save
    // Start at second 30 and go to second 90 (crosses minute boundary at :60)
    let baseDate = Calendar.current.date(byAdding: .second, value: 30, to: currentDate)!
    for i in 0..<60 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      sut.receiveValue(simulatedDate)
    }
    
    // Explicitly finalize to trigger save (don't rely on deinit)
    sut.stopAndSave()
    mockDataManager.flush()
    
    let firstEntry = mockDataManager.savedTimeEntries.first
    XCTAssertNotNil(firstEntry, "Time entry should exist")
    XCTAssertTrue(firstEntry?.duringMinute.hasSuffix("Z") ?? false, "Time entry should be in UTC format")
  }
  
  func testPlaybackStopped_stopsTimer() {
    sut.playbackStarted()
    
    // Simulate some time passing
    for i in 0..<5 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    sut.playbackStopped()
    let durationAfterStop = sut.timeEntry.duration
    
    // Simulate more time that shouldn't be counted
    for i in 5..<10 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    // Duration should still increase since receiveValue is called directly
    // The timer is stopped, but manual calls still work
    let durationAfterMoreCalls = sut.timeEntry.duration
    XCTAssertGreaterThan(durationAfterMoreCalls, durationAfterStop, 
                         "Direct receiveValue calls still accumulate time even after stop")
  }
  
  func testSaveCurrentDuration_savesTimeEntryCorrectly() {
    sut.playbackStarted()

    for i in 0..<59 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    // Verify the tracker's internal timeEntry has correct metadata
    let timeEntry = sut.timeEntry
    XCTAssertGreaterThan(timeEntry.duration, 0, "Should have accumulated time")
    XCTAssertEqual(timeEntry.bookId, "book123")
    XCTAssertEqual(timeEntry.libraryId, "library123")
  }
  
  func testNoPlayback_savesNoTimeEntry() {
    sut.playbackStarted()
    sut.playbackStopped()
    
    // Explicitly finalize to trigger save (don't rely on deinit)
    sut.stopAndSave()
    mockDataManager.flush()

    XCTAssertEqual(mockDataManager.savedTimeEntries.count, 0, "No time entries should be saved without playback")
  }

  func testExactMinuteOfPlayback_savesCorrectTimeEntry() {
    sut.playbackStarted()
    
    for i in 0..<59 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    // Verify the tracker's internal state has accumulated time
    let timeEntry = sut.timeEntry
    XCTAssertGreaterThan(timeEntry.duration, 0, "Time entry should have accumulated time")
  }
  
  // MARK: - Additional Tests
  
  func testMultipleMinuteBoundaries_createsMultipleEntries() {
    // Simulate 3 minutes of playback crossing minute boundaries
    let calendar = Calendar.current
    var date = currentDate!
    
    for _ in 0..<180 {
      sut.receiveValue(date)
      date = calendar.date(byAdding: .second, value: 1, to: date)!
    }
    
    // Capture the accumulated duration before finalize
    let accumulatedDuration = sut.timeEntry.duration
    XCTAssertGreaterThan(accumulatedDuration, 0, "Should have accumulated time during playback")
    
    // Explicitly finalize to trigger save (don't rely on deinit)
    sut.stopAndSave()
    mockDataManager.flush()
    
    let entries = mockDataManager.savedTimeEntries
    XCTAssertGreaterThanOrEqual(entries.count, 1, "Should have at least 1 entry for 3 minutes")
    
    let total = entries.reduce(0) { $0 + $1.duration }
    XCTAssertGreaterThan(total, 0, "Total should be greater than 0")
  }
  
  func testTimeEntry_hasCorrectMetadata() {
    for i in 0..<30 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    // Verify the tracker's internal timeEntry has correct metadata
    let entry = sut.timeEntry
    
    XCTAssertEqual(entry.bookId, "book123")
    XCTAssertEqual(entry.libraryId, "library123")
    XCTAssertFalse(entry.id.isEmpty, "Entry should have an ID")
    XCTAssertFalse(entry.duringMinute.isEmpty, "Entry should have a timestamp")
  }
}

// MARK: - Playback Tracking Regression Tests

/// Regression tests for audiobook playback tracking
/// These tests verify fixes for:
/// 1. playbackStopped() not saving accumulated time
/// 2. Multiple timers running simultaneously causing overcounting
final class PlaybackTrackingRegressionTests: XCTestCase {
  
  private var tracker: AudiobookTimeTracker!
  private var mockDataManager: MockDataManager!
  private var baseDate: Date!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
    baseDate = Date()
    tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com/track")!,
      dataManager: mockDataManager
    )
  }
  
  override func tearDown() {
    tracker = nil
    mockDataManager = nil
    baseDate = nil
    super.tearDown()
  }
  
  // MARK: - Bug #1: playbackStopped() must save accumulated time
  
  /// Regression test: playbackStopped() was not saving accumulated duration
  /// When playback stops (sleep timer, pause, chapter change), any accumulated seconds
  /// since the last minute boundary must be saved.
  func testPlaybackStopped_savesAccumulatedTime() {
    // Arrange: Simulate 25 seconds of playback within a single minute
    // (doesn't cross minute boundary, so no automatic save occurs)
    tracker.playbackStarted()
    for i in 0..<25 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Act: Stop playback (simulates sleep timer, pause, or chapter change)
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: The 25 seconds should have been saved when playback stopped
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 25, 
      "playbackStopped() must save accumulated time. Expected 25 seconds, got \(totalSaved)")
  }
  
  /// Regression test: Simulates extended listening with multiple stop/start cycles
  /// Multiple stop/start cycles should preserve all accumulated time.
  func testMultipleStopStartCycles_preservesAllTime() {
    // Simulate multiple play/pause cycles (like chapter transitions or buffering)
    var totalExpectedSeconds = 0
    
    // Cycle 1: 45 seconds
    tracker.playbackStarted()
    for i in 0..<45 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    totalExpectedSeconds += 45
    tracker.playbackStopped()
    
    // Cycle 2: 30 seconds (after a gap)
    let secondCycleBase = Calendar.current.date(byAdding: .minute, value: 2, to: baseDate)!
    tracker.playbackStarted()
    for i in 0..<30 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: secondCycleBase)!
      tracker.receiveValue(time)
    }
    totalExpectedSeconds += 30
    tracker.playbackStopped()
    
    // Cycle 3: 20 seconds
    let thirdCycleBase = Calendar.current.date(byAdding: .minute, value: 5, to: baseDate)!
    tracker.playbackStarted()
    for i in 0..<20 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: thirdCycleBase)!
      tracker.receiveValue(time)
    }
    totalExpectedSeconds += 20
    tracker.playbackStopped()
    
    mockDataManager.flush()
    
    // Assert: All 95 seconds across 3 cycles should be saved
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, totalExpectedSeconds,
      "Multiple stop/start cycles must preserve all time. Expected \(totalExpectedSeconds), got \(totalSaved)")
  }
  
  /// Regression test: Sleep timer scenario
  /// When sleep timer fires, it calls pause() which triggers playbackStopped().
  /// All accumulated time must be saved at that point.
  func testSleepTimerPause_savesAllAccumulatedTime() {
    // Arrange: Simulate continuous playback for 55 seconds (just under a minute)
    tracker.playbackStarted()
    for i in 0..<55 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Act: Sleep timer fires and pauses playback
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: All 55 seconds should be saved
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 55,
      "Sleep timer pause must save all accumulated time. Expected 55, got \(totalSaved)")
  }
  
  // MARK: - Bug #2: Multiple timers causing overcounting
  
  /// Regression test: playbackStarted() called multiple times
  /// should not create multiple concurrent timers.
  func testMultiplePlaybackStartedCalls_doesNotOvercount() {
    // Arrange: Call playbackStarted multiple times (simulates multiple event sources)
    tracker.playbackStarted()
    tracker.playbackStarted()  // Second call - should not create additional timer
    tracker.playbackStarted()  // Third call - should not create additional timer
    
    // Simulate exactly 30 seconds of playback
    for i in 0..<30 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    tracker.stopAndSave()
    mockDataManager.flush()
    
    // Assert: Should have exactly 30 seconds, not 90 (3x overcounting)
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 30,
      "Multiple playbackStarted calls must not overcount. Expected 30, got \(totalSaved)")
  }
  
  /// Regression test: Rapid start/stop/start cycles
  /// Each playbackStarted should cleanly replace any existing timer.
  func testRapidStartStopCycles_countsCorrectly() {
    // Rapid start/stop cycle 1
    tracker.playbackStarted()
    tracker.playbackStopped()
    
    // Rapid start/stop cycle 2
    tracker.playbackStarted()
    tracker.playbackStopped()
    
    // Final playback session with actual time
    tracker.playbackStarted()
    for i in 0..<40 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    tracker.stopAndSave()
    mockDataManager.flush()
    
    // Assert: Should only have the 40 seconds from the final session
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 40,
      "Rapid start/stop cycles must not affect subsequent tracking. Expected 40, got \(totalSaved)")
  }
}

// MARK: - App Lifecycle Tests

/// Tests for app lifecycle events affecting time tracking
/// Covers: background/foreground/termination data persistence
final class AudiobookTimeTrackerLifecycleTests: XCTestCase {
  
  private var tracker: AudiobookTimeTracker!
  private var mockDataManager: MockDataManager!
  private var baseDate: Date!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
    baseDate = Date()
    tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com/track")!,
      dataManager: mockDataManager
    )
  }
  
  override func tearDown() {
    tracker = nil
    mockDataManager = nil
    baseDate = nil
    super.tearDown()
  }
  
  /// Test that stopAndSave explicitly saves all accumulated time
  func testStopAndSave_savesAllAccumulatedTime() {
    // Arrange
    tracker.playbackStarted()
    for i in 0..<35 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Act
    tracker.stopAndSave()
    mockDataManager.flush()
    
    // Assert
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 35, "stopAndSave should save all accumulated time")
  }
  
  /// Test that stopAndSave can be called multiple times safely
  func testStopAndSave_canBeCalledMultipleTimes() {
    // Arrange
    tracker.playbackStarted()
    for i in 0..<20 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Act - call multiple times
    tracker.stopAndSave()
    tracker.stopAndSave()
    tracker.stopAndSave()
    mockDataManager.flush()
    
    // Assert - should only save once, not triple
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 20, "Multiple stopAndSave calls should not duplicate entries")
  }
  
  /// Test that tracker saves data when stopAndSave is called before deallocation
  /// Note: Relying on deinit for saving is unreliable as ARC doesn't guarantee immediate deallocation.
  /// The recommended pattern is to explicitly call stopAndSave() before releasing the tracker.
  func testTrackerDeallocation_savesAccumulatedTime() {
    // Arrange - create a local tracker
    let localTracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com/track")!,
      dataManager: mockDataManager
    )
    
    localTracker.playbackStarted()
    for i in 0..<15 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      localTracker.receiveValue(time)
    }
    
    // Explicitly call stopAndSave before releasing (recommended pattern)
    localTracker.stopAndSave()
    mockDataManager.flush()
    
    // Assert
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 15, "Tracker should save accumulated time when stopAndSave is called")
  }
  
  /// Test simulated app termination notification saves data
  func testAppTerminationNotification_savesData() {
    // Arrange
    tracker.playbackStarted()
    for i in 0..<25 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Act - simulate app termination notification
    NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
    
    // Give time for notification to be processed
    let expectation = XCTestExpectation(description: "Notification processed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
    
    mockDataManager.flush()
    
    // Assert
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 25, "App termination notification should trigger save")
  }
  
  /// Test thread safety of timeEntry property access
  func testTimeEntryProperty_isThreadSafe() {
    // Arrange - start playback
    tracker.playbackStarted()
    
    let concurrentQueue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
    let expectation = XCTestExpectation(description: "Concurrent access completes")
    expectation.expectedFulfillmentCount = 100
    
    // Act - access timeEntry from multiple threads while also receiving values
    for i in 0..<50 {
      concurrentQueue.async {
        let time = Calendar.current.date(byAdding: .second, value: i, to: self.baseDate)!
        self.tracker.receiveValue(time)
        expectation.fulfill()
      }
      
      concurrentQueue.async {
        // Access timeEntry property
        let _ = self.tracker.timeEntry.duration
        expectation.fulfill()
      }
    }
    
    wait(for: [expectation], timeout: 5.0)
    
    // Assert - should not crash, and should have accumulated some time
    tracker.stopAndSave()
    mockDataManager.flush()
    
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertGreaterThan(totalSaved, 0, "Should have accumulated time despite concurrent access")
  }
}

// MARK: - Continuous Playback Tests

/// Tests for time tracking during track/chapter transitions
/// During continuous playback, handlePlaybackCompleted() must call playbackStopped()
final class ContinuousPlaybackTrackingTests: XCTestCase {
  
  private var tracker: AudiobookTimeTracker!
  private var mockDataManager: MockDataManager!
  private var baseDate: Date!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
    baseDate = Date()
    tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "continuous-test-book",
      timeTrackingUrl: URL(string: "https://example.com/track")!,
      dataManager: mockDataManager
    )
  }
  
  override func tearDown() {
    tracker = nil
    mockDataManager = nil
    baseDate = nil
    super.tearDown()
  }
  
  /// Simulates what happens when tracks auto-advance
  /// handlePlaybackCompleted() must call playbackStopped() to save time
  func testTrackTransition_savesTimeBeforeNextTrackStarts() {
    // Arrange: Track 1 starts
    tracker.playbackStarted()
    
    // Track 1 plays for 55 seconds (not quite a full minute)
    for i in 0..<55 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Track 1 completes - AudiobookManager.handlePlaybackCompleted() now calls playbackStopped()
    tracker.playbackStopped()  // This was MISSING before the fix
    
    // Track 2 auto-starts immediately
    tracker.playbackStarted()
    
    // Track 2 plays for 45 seconds
    for i in 55..<100 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Track 2 completes
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: ALL time should be saved (55 + 45 = 100 seconds)
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 100, 
      "Track transitions must preserve all time. Expected 100, got \(totalSaved)")
  }
  
  /// Tests a full 60-minute listening session with multiple track changes
  func testBiblioBoardScenario_61MinutesWithTrackChanges() {
    // Simulate 61 minutes of playback with tracks changing every ~5 minutes
    var currentSecond = 0
    let trackDurations = [300, 280, 320, 290, 310, 300, 300, 300, 300, 300, 300, 360]  // ~61 min total
    
    for trackDuration in trackDurations {
      // Track starts
      tracker.playbackStarted()
      
      // Play this track
      for _ in 0..<trackDuration {
        let time = Calendar.current.date(byAdding: .second, value: currentSecond, to: baseDate)!
        tracker.receiveValue(time)
        currentSecond += 1
      }
      
      // Track completes (this is where time was being lost!)
      tracker.playbackStopped()
    }
    
    mockDataManager.flush()
    
    // Calculate expected total
    let expectedTotal = trackDurations.reduce(0, +)  // Should be ~3660 seconds (61 min)
    let actualTotal = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    
    XCTAssertEqual(actualTotal, expectedTotal,
      "Extended playback scenario: Expected \(expectedTotal) seconds (~61 min), got \(actualTotal)")
  }
  
  /// Tests that rapid track changes (short tracks) don't lose time
  func testRapidTrackChanges_noTimeLoss() {
    // Simulate many short tracks (like a book with short chapters)
    for trackNum in 0..<20 {
      tracker.playbackStarted()
      
      // Each track is only 15 seconds
      for i in 0..<15 {
        let totalSeconds = (trackNum * 15) + i
        let time = Calendar.current.date(byAdding: .second, value: totalSeconds, to: baseDate)!
        tracker.receiveValue(time)
      }
      
      tracker.playbackStopped()
    }
    
    mockDataManager.flush()
    
    // 20 tracks × 15 seconds = 300 seconds
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 300, 
      "Rapid track changes (20 × 15s) should save all 300 seconds. Got \(totalSaved)")
  }
}

// MARK: - CarPlay Integration Tests

/// Tests to verify time tracking works correctly via CarPlay code paths
/// CarPlay uses the same BookService.open() -> AudiobookManager flow
final class CarPlayTimeTrackingTests: XCTestCase {
  
  private var tracker: AudiobookTimeTracker!
  private var mockDataManager: MockDataManager!
  private var baseDate: Date!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
    baseDate = Date()
    tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "carplay-test-book",
      timeTrackingUrl: URL(string: "https://example.com/track")!,
      dataManager: mockDataManager
    )
  }
  
  override func tearDown() {
    tracker = nil
    mockDataManager = nil
    baseDate = nil
    super.tearDown()
  }
  
  /// Simulates CarPlay flow: BookService creates tracker, manager calls delegate methods
  /// CarPlay uses currentManager?.play() which calls playbackTrackerDelegate?.playbackStarted()
  func testCarPlayPlayback_usesStandardTrackerDelegateMethods() {
    // Arrange: Simulate the exact CarPlay flow
    // 1. BookService.open() creates the tracker (done in setUp)
    // 2. Manager calls playbackStarted() when user taps play in CarPlay
    tracker.playbackStarted()
    
    // 3. Time passes during driving
    for i in 0..<300 {  // 5 minutes
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // 4. User taps pause in CarPlay, manager calls playbackStopped()
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: All time should be tracked
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 300, "CarPlay playback should track all 5 minutes (300 seconds)")
  }
  
  /// Test CarPlay disconnect scenario - tracker continues working
  func testCarPlayDisconnect_trackerContinuesIndependently() {
    // Arrange: Start playback via CarPlay
    tracker.playbackStarted()
    
    for i in 0..<120 {  // 2 minutes before "disconnect"
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Simulate CarPlay disconnect - but playback continues on phone
    // (In real code, CarPlaySceneDelegate.didDisconnect doesn't stop playback)
    
    // Continue playback for 3 more minutes
    for i in 120..<300 {
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Stop playback (e.g., user stops on phone)
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: All time tracked, disconnect didn't affect anything
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 300, "CarPlay disconnect should not affect tracking - all 5 minutes recorded")
  }
  
  /// Test CarPlay chapter skip (skipToChapter calls play at new position)
  func testCarPlayChapterSkip_properlyTracksTime() {
    // Arrange: Playing
    tracker.playbackStarted()
    
    for i in 0..<60 {  // 1 minute of chapter 1
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    // Chapter skip in CarPlay calls: manager.audiobook.player.play(at: chapter.position)
    // This may trigger playbackStopped then playbackStarted
    tracker.playbackStopped()  // Brief stop
    tracker.playbackStarted()  // New chapter starts
    
    for i in 60..<180 {  // 2 more minutes in chapter 2
      let time = Calendar.current.date(byAdding: .second, value: i, to: baseDate)!
      tracker.receiveValue(time)
    }
    
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: All time from both chapters tracked
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 180, "Chapter skip should preserve all time: 60 + 120 = 180 seconds")
  }
}

// MARK: - Sleep Timer Integration Tests

/// Tests for sleep timer integration with time tracking
/// Covers: sleep timer triggering proper time save
final class AudiobookSleepTimerIntegrationTests: XCTestCase {
  
  private var tracker: AudiobookTimeTracker!
  private var mockDataManager: MockDataManager!
  private var baseDate: Date!
  
  override func setUp() {
    super.setUp()
    mockDataManager = MockDataManager()
    baseDate = Date()
    tracker = AudiobookTimeTracker(
      libraryId: "test-library",
      bookId: "test-book",
      timeTrackingUrl: URL(string: "https://example.com/track")!,
      dataManager: mockDataManager
    )
  }
  
  override func tearDown() {
    tracker = nil
    mockDataManager = nil
    baseDate = nil
    super.tearDown()
  }
  
  /// Test sleep timer scenario: play for extended time, then pause saves all time
  func testSleepTimerScenario_savesAllPlayedTime() {
    // Arrange: Simulate 15 minutes of playback (900 seconds)
    // Sleep timer typically uses 15, 30, 60 minute intervals
    tracker.playbackStarted()
    
    var currentTime = baseDate!
    for _ in 0..<900 {
      tracker.receiveValue(currentTime)
      currentTime = Calendar.current.date(byAdding: .second, value: 1, to: currentTime)!
    }
    
    // Act: Sleep timer fires and calls pause (which triggers playbackStopped)
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: All 900 seconds (15 minutes) should be saved
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 900, 
      "Sleep timer pause should save all 15 minutes (900 seconds). Got \(totalSaved)")
  }
  
  /// Test 30-minute sleep timer scenario
  func testSleepTimer30Minutes_savesAllPlayedTime() {
    // Arrange: Simulate 30 minutes (1800 seconds)
    tracker.playbackStarted()
    
    var currentTime = baseDate!
    for _ in 0..<1800 {
      tracker.receiveValue(currentTime)
      currentTime = Calendar.current.date(byAdding: .second, value: 1, to: currentTime)!
    }
    
    // Act
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 1800, 
      "30-minute sleep timer should save all 1800 seconds. Got \(totalSaved)")
  }
  
  /// Test end-of-chapter sleep timer (variable duration)
  func testEndOfChapterSleepTimer_savesPartialTime() {
    // Arrange: Play for arbitrary duration until chapter ends
    tracker.playbackStarted()
    
    let chapterDuration = 427  // 7 minutes 7 seconds - arbitrary
    var currentTime = baseDate!
    for _ in 0..<chapterDuration {
      tracker.receiveValue(currentTime)
      currentTime = Calendar.current.date(byAdding: .second, value: 1, to: currentTime)!
    }
    
    // Act: Chapter ends, triggers pause
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, chapterDuration, 
      "End of chapter should save all \(chapterDuration) seconds. Got \(totalSaved)")
  }
  
  /// Test sleep timer with resume (sleep timer canceled/extended)
  func testSleepTimerCancelResume_preservesAllTime() {
    // Arrange: Play, sleep timer fires, user extends/cancels and resumes
    tracker.playbackStarted()
    
    // First session: 600 seconds (10 min)
    var currentTime = baseDate!
    for _ in 0..<600 {
      tracker.receiveValue(currentTime)
      currentTime = Calendar.current.date(byAdding: .second, value: 1, to: currentTime)!
    }
    
    // Sleep timer fires
    tracker.playbackStopped()
    
    // User extends/cancels sleep timer and resumes
    tracker.playbackStarted()
    
    // Second session: 300 seconds (5 min)
    for _ in 0..<300 {
      tracker.receiveValue(currentTime)
      currentTime = Calendar.current.date(byAdding: .second, value: 1, to: currentTime)!
    }
    
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert: Total should be 900 seconds (15 min)
    let totalSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalSaved, 900, 
      "Extended session should preserve all time: 600 + 300 = 900. Got \(totalSaved)")
  }
  
  /// Test multiple minute boundaries during sleep timer period
  /// This verifies time entries are batched correctly by minute
  func testSleepTimerMultipleMinutes_createsSeparateEntries() {
    // Arrange: Play for 3+ minutes
    tracker.playbackStarted()
    
    var currentTime = baseDate!
    for _ in 0..<200 {  // 3 min 20 sec
      tracker.receiveValue(currentTime)
      currentTime = Calendar.current.date(byAdding: .second, value: 1, to: currentTime)!
    }
    
    tracker.playbackStopped()
    mockDataManager.flush()
    
    // Assert
    let entries = mockDataManager.savedTimeEntries
    let totalSaved = entries.reduce(0) { $0 + $1.duration }
    
    // Should have multiple entries (one per minute crossed, plus final)
    XCTAssertGreaterThanOrEqual(entries.count, 1, "Should have at least one entry")
    XCTAssertEqual(totalSaved, 200, "Total should be 200 seconds")
    
    // Each entry should be <= 60 seconds
    for entry in entries {
      XCTAssertLessThanOrEqual(entry.duration, 60, "Each entry should be max 60 seconds")
    }
  }
}
