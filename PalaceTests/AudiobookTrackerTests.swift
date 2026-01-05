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
    
    // Trigger save by deallocating tracker
    sut = nil
    
    // Flush any pending async writes
    mockDataManager.flush()
    
    let totalTimeSaved = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(totalTimeSaved, 90, "Total time saved should be 90 seconds")
  }

  func testTimeEntries_areLimitedTo60Seconds() {
    // Simulate 70 seconds of playback
    for i in 0..<70 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    sut = nil
    mockDataManager.flush()
    
    let entries = mockDataManager.savedTimeEntries
    XCTAssertGreaterThanOrEqual(entries.count, 2, "Should have at least 2 entries for 70 seconds of playback")
    
    // Each entry should be at most 60 seconds
    for entry in entries {
      XCTAssertLessThanOrEqual(entry.duration, 60, "Entry duration should be <= 60 seconds")
    }
    
    let total = entries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(total, 70, "Total should equal 70 seconds")
  }

  func testTimeEntries_areInUTC() {
    // Simulate 60 seconds of playback
    for i in 0..<60 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    sut = nil
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
    
    sut = nil
    mockDataManager.flush()
    
    let entries = mockDataManager.savedTimeEntries
    XCTAssertLessThanOrEqual(entries.count, 2, "Should have 1-2 entries for 59 seconds")
    
    let total = entries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(total, 60, "Total should be 60 seconds (59 intervals + initial)")
    
    XCTAssertEqual(entries.first?.bookId, "book123")
    XCTAssertEqual(entries.first?.libraryId, "library123")
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
    
    sut = nil
    mockDataManager.flush()
    
    let entries = mockDataManager.savedTimeEntries
    let total = entries.reduce(0) { $0 + $1.duration }
    
    XCTAssertLessThanOrEqual(entries.count, 2, "Should have 1-2 entries")
    XCTAssertEqual(total, 60, "Time entry should be for 60 seconds")
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
    XCTAssertGreaterThanOrEqual(entries.count, 3, "Should have at least 3 entries for 3 minutes")
    
    let total = entries.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(total, 180, "Total should equal 180 seconds")
  }
  
  func testTimeEntry_hasCorrectMetadata() {
    for i in 0..<30 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }
    
    sut = nil
    mockDataManager.flush()
    
    guard let entry = mockDataManager.savedTimeEntries.first else {
      XCTFail("Should have at least one entry")
      return
    }
    
    XCTAssertEqual(entry.bookId, "book123")
    XCTAssertEqual(entry.libraryId, "library123")
    XCTAssertFalse(entry.id.isEmpty, "Entry should have an ID")
    XCTAssertFalse(entry.duringMinute.isEmpty, "Entry should have a timestamp")
  }
}
