//
//  AudiobookPlayerSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class AudiobookPlayerSnapshotTests: XCTestCase {
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // MARK: - AudiobookSampleToolbar
  
  func testAudiobookSampleToolbar_withSample() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.snapshotAudiobook()
    
    guard let toolbar = AudiobookSampleToolbar(book: book) else {
      return
    }
    
    let view = toolbar
      .frame(width: 390, height: 80)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Accessibility
  
  func testAudiobookPlayerAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.playerView.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.playPauseButton.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.skipBackButton.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.skipForwardButton.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.progressSlider.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.currentTimeLabel.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.remainingTimeLabel.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.playbackSpeedButton.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.sleepTimerButton.isEmpty)
    XCTAssertFalse(AccessibilityID.AudiobookPlayer.tocButton.isEmpty)
  }
}
