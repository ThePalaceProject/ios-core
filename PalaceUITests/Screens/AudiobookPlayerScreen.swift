import XCTest

final class AudiobookPlayerScreen: ScreenObject {
  
  var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
  }
  
  var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
  }
  
  var chapterTitleLabel: XCUIElement {
    app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
  }
  
  @discardableResult
  override func isDisplayed(timeout: TimeInterval = 5.0) -> Bool {
    playPauseButton.waitForExistence(timeout: timeout)
  }
  
  func getCurrentTime() -> TimeInterval {
    guard currentTimeLabel.exists else { return 0 }
    return TestHelpers.parseTimeLabel(currentTimeLabel.label)
  }
  
  func tapPlayButton() {
    playPauseButton.tap()
  }
  
  @discardableResult
  func verifyPlaybackAdvances(duration: TimeInterval = 5.0) -> Bool {
    let time1 = getCurrentTime()
    TestHelpers.waitFor(duration)
    let time2 = getCurrentTime()
    
    let advanced = time2 - time1
    XCTAssertGreaterThan(advanced, duration * 0.9, "Playback should advance")
    return advanced > duration * 0.9
  }
}
