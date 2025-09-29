//
//  AudiobookTrackerTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 9/5/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

// MARK: - MockDataManager

class MockDataManager: DataManager {
  var savedTimeEntries: [TimeEntry] = []

  func save(time: TimeEntry) {
    savedTimeEntries.append(time)
  }

  func removeSynchronizedEntries(ids: [String]) {
    savedTimeEntries.removeAll { ids.contains($0.id) }
  }

  func saveStore() {}

  func loadStore() {}

  func cleanUpUrls() {}

  func syncValues() {}
}

// MARK: - AudiobookTimeTrackerTests

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
    let expectation = expectation(description: "Aggregate time saved")

    for i in 0..<90 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }

    sut = nil

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      let totalTimeSaved = self.mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
      XCTAssertEqual(totalTimeSaved, 90, "Total time saved should be 90 seconds")
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 3.0)
  }

  func testTimeEntries_areLimitedTo60Seconds() {
    let expectation = expectation(description: "Limit time entry duration to 60 seconds")

    for i in 0..<70 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }

    sut = nil

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      XCTAssertGreaterThanOrEqual(
        self.mockDataManager.savedTimeEntries.count,
        2,
        "There should be at least 2 entries since the playback spanned 2 minutes."
      )

      XCTAssertLessThanOrEqual(
        self.mockDataManager.savedTimeEntries.first!.duration,
        60,
        "First entry should be less than or equal to 60 seconds"
      )
      XCTAssertLessThanOrEqual(
        self.mockDataManager.savedTimeEntries.last!.duration,
        60,
        "Last entry should be less than or equal to 60 seconds"
      )

      let total = self.mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }

      XCTAssertEqual(total, 70, "Total should equal 70 seconds")

      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)
  }

  func testTimeEntries_areInUTC() {
    // Arrange
    let expectation = expectation(description: "Time entries should be in UTC")

    // Simulate 60 seconds of playback
    for i in 0..<60 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      let firstEntry = self.mockDataManager.savedTimeEntries.first
      XCTAssertNotNil(firstEntry, "Time entry should exist")
      XCTAssertTrue(firstEntry?.duringMinute.hasSuffix("Z") ?? false, "Time entry should be in UTC format")
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)
  }

  func testPlaybackStopped_stopsTimer() {
    sut.playbackStarted()
    let expectation = expectation(description: "Timer stopped")

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      self.sut.playbackStopped()
      let previousDuration = self.sut.timeEntry.duration

      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        XCTAssertEqual(self.sut.timeEntry.duration, previousDuration)
        expectation.fulfill()
      }
    }

    wait(for: [expectation], timeout: 10.0)
  }

  func testSaveCurrentDuration_savesTimeEntryCorrectly() {
    sut.playbackStarted()
    let expectation = expectation(description: "Saved Time entry Correctly")

    for i in 0..<59 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }

    sut = nil

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      XCTAssertLessThanOrEqual(
        self.mockDataManager.savedTimeEntries.count,
        2,
        "There should be less than or equal to 2 entries."
      )
      let total = self.mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }

      XCTAssertEqual(total, 60, "Total should be less than or equal to 60")

      XCTAssertEqual(self.mockDataManager.savedTimeEntries.first?.bookId, "book123")
      XCTAssertEqual(self.mockDataManager.savedTimeEntries.first?.libraryId, "library123")
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 3.0)
  }

  func testNoPlayback_savesNoTimeEntry() {
    sut.playbackStarted()
    sut.playbackStopped()

    XCTAssertEqual(mockDataManager.savedTimeEntries.count, 0, "No time entries should be saved without playback")
  }

  func testExactMinuteOfPlayback_savesCorrectTimeEntry() {
    sut.playbackStarted()
    let expectation = expectation(description: "Saved Time entry Correctly")

    for i in 0..<59 {
      let simulatedDate = Calendar.current.date(byAdding: .second, value: i, to: currentDate)!
      sut.receiveValue(simulatedDate)
    }

    sut = nil

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      let total = self.mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }

      XCTAssertLessThanOrEqual(
        self.mockDataManager.savedTimeEntries.count,
        2,
        "There should be less than or equal to 2 entries."
      )
      XCTAssertEqual(total, 60, "Time entry should be for 60 seconds")
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)
  }
}
