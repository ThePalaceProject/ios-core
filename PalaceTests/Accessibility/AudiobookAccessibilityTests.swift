//
//  AudiobookAccessibilityTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility in audiobook-related UI elements.
//  Verifies playback controls have proper labels for blind users.
//  (PP-3292)
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AudiobookAccessibilityTests: XCTestCase {
  
  // MARK: - Play/Pause Button Tests
  
  /// Verifies play label is descriptive
  func testPlayLabel_isDescriptive() {
    let label = Strings.Generic.playAudiobook
    
    XCTAssertFalse(label.isEmpty, "Play label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("play") || lowercased.contains("start") || lowercased.contains("resume"),
      "Play label should indicate play action"
    )
  }
  
  /// Verifies pause label is descriptive
  func testPauseLabel_isDescriptive() {
    let label = Strings.Generic.pauseAudiobook
    
    XCTAssertFalse(label.isEmpty, "Pause label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("pause") || lowercased.contains("stop"),
      "Pause label should indicate pause action"
    )
  }
  
  /// Verifies play and pause labels are different
  func testPlayPauseLabels_areDifferent() {
    let playLabel = Strings.Generic.playAudiobook
    let pauseLabel = Strings.Generic.pauseAudiobook
    
    XCTAssertNotEqual(
      playLabel,
      pauseLabel,
      "Play and pause labels should be different to indicate state change"
    )
  }
  
  /// Verifies play/pause labels change based on playback state
  func testPlayPauseLabel_changesWithState() {
    // Simulate what AudiobookSampleToolbar does
    let isPlaying = true
    let labelWhenPlaying = isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook
    
    let isNotPlaying = false
    let labelWhenNotPlaying = isNotPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook
    
    XCTAssertNotEqual(
      labelWhenPlaying,
      labelWhenNotPlaying,
      "Label should change based on playback state"
    )
    XCTAssertEqual(labelWhenPlaying, Strings.Generic.pauseAudiobook)
    XCTAssertEqual(labelWhenNotPlaying, Strings.Generic.playAudiobook)
  }
  
  // MARK: - Skip Button Tests
  
  /// Verifies skip back label is descriptive and includes duration
  func testSkipBackLabel_isDescriptiveWithDuration() {
    let label = Strings.Generic.skipBack30
    
    XCTAssertFalse(label.isEmpty, "Skip back label should not be empty")
    let lowercased = label.lowercased()
    
    // Should indicate backward action
    XCTAssertTrue(
      lowercased.contains("back") || lowercased.contains("rewind") || lowercased.contains("skip"),
      "Skip back label should indicate backward navigation"
    )
    
    // Should include duration (30 seconds)
    XCTAssertTrue(
      lowercased.contains("30") || lowercased.contains("thirty"),
      "Skip back label should include the duration (30 seconds)"
    )
  }
  
  /// Verifies skip back label indicates seconds
  func testSkipBackLabel_indicatesTimeUnit() {
    let label = Strings.Generic.skipBack30
    let lowercased = label.lowercased()
    
    XCTAssertTrue(
      lowercased.contains("second"),
      "Skip back label should indicate time unit (seconds)"
    )
  }
  
  // MARK: - Audiobook Indicator Tests
  
  /// Verifies audiobook indicator label exists for book cells
  func testAudiobookIndicator_labelExists() {
    let label = Strings.Generic.audiobook
    
    XCTAssertFalse(label.isEmpty, "Audiobook indicator label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("audio"),
      "Audiobook label should contain 'audio'"
    )
  }
}
