import XCTest

final class AudiobookPlayerScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var playerView: XCUIElement { app.otherElements[AccessibilityID.AudiobookPlayer.playerView] }
  var closeButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.closeButton] }

  // Playback controls
  var playPauseButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton] }
  var skipBackButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.skipBackButton] }
  var skipForwardButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.skipForwardButton] }
  var rewindButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.rewindButton] }
  var fastForwardButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.fastForwardButton] }

  // Progress
  var progressSlider: XCUIElement { app.sliders[AccessibilityID.AudiobookPlayer.progressSlider] }
  var currentTimeLabel: XCUIElement { app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel] }
  var remainingTimeLabel: XCUIElement { app.staticTexts[AccessibilityID.AudiobookPlayer.remainingTimeLabel] }
  var chapterTitle: XCUIElement { app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle] }

  // Settings
  var playbackSpeedButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeedButton] }
  var sleepTimerButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.sleepTimerButton] }
  var tocButton: XCUIElement { app.buttons[AccessibilityID.AudiobookPlayer.tocButton] }

  // Table of contents
  var tocView: XCUIElement { app.otherElements[AccessibilityID.AudiobookPlayer.tocView] }

  func tocChapter(at index: Int) -> XCUIElement {
    app.cells[AccessibilityID.AudiobookPlayer.tocChapter(index)]
  }

  // MARK: - Actions

  @discardableResult
  func tapPlayPause() -> AudiobookPlayerScreen {
    playPauseButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapSkipForward() -> AudiobookPlayerScreen {
    skipForwardButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapSkipBack() -> AudiobookPlayerScreen {
    skipBackButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapPlaybackSpeed() -> AudiobookPlayerScreen {
    playbackSpeedButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapSleepTimer() -> AudiobookPlayerScreen {
    sleepTimerButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapTOC() -> AudiobookPlayerScreen {
    tocButton.waitAndTap()
    return self
  }

  @discardableResult
  func close() -> BookDetailScreen {
    closeButton.waitAndTap()
    return BookDetailScreen(app: app)
  }

  // MARK: - Assertions

  func verifyLoaded() {
    let hasPlayer = playerView.waitForExistence(timeout: 15)
      || playPauseButton.waitForExistence(timeout: 15)
    XCTAssertTrue(hasPlayer, "Audiobook player should be visible")
  }

  func verifyPlaybackControls() {
    XCTAssertTrue(playPauseButton.exists, "Play/pause button should exist")
    XCTAssertTrue(skipForwardButton.exists || fastForwardButton.exists, "Skip forward should exist")
    XCTAssertTrue(skipBackButton.exists || rewindButton.exists, "Skip back should exist")
  }
}
