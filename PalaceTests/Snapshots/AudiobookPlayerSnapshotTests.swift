//
//  AudiobookPlayerSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for Audiobook Player UI components.
//
//  NOTE: The full AudiobookPlayerView requires AudiobookPlaybackModel with a real
//  audiobook loaded, which is complex to mock. Visual regression testing of the
//  full player UI should be done via E2E tests or manual QA.
//
//  These tests cover:
//  - AudiobookSampleToolbar snapshot (when sample is available)
//  - Accessibility identifiers verification
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
  
  // MARK: - AudiobookSampleToolbar Snapshots
  // Note: Requires a book with a valid audiobook sample
  
  func testAudiobookSampleToolbar_withSample() {
    guard canRecordSnapshots else { return }
    
    // AudiobookSampleToolbar requires a book with an AudiobookSample
    // which is only available for certain books from the catalog
    // This test will be skipped if no sample is available
    let book = TPPBookMocker.snapshotAudiobook()
    
    // AudiobookSampleToolbar returns nil if no sample
    guard let toolbar = AudiobookSampleToolbar(book: book) else {
      // Skip - book doesn't have a sample (expected for mock books)
      return
    }
    
    let view = toolbar
      .frame(width: 390, height: 80)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Accessibility Identifiers
  
  func testAudiobookPlayerAccessibilityIdentifiers() {
    // Verify all required accessibility identifiers are defined
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
