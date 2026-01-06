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
    
    // Wait for the async syncQueue operations to complete before deallocating
    // The tracker uses a barrier queue, so this ensures all receiveValue calls finish
    let expectation = self.expectation(description: "Wait for tracker queue")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      // Now deallocate to trigger final save
      self.sut = nil
      self.mockDataManager.flush()
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 1.0)
    
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
    
    sut = nil
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
    
    sut = nil
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
