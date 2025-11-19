import Foundation
import Cucumberish
import XCTest

class PalaceAudiobookSteps {
  static func setup() {
    let app = TestHelpers.app
    
    When("I tap the play button") { _, _ in
      let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
      if TestHelpers.waitForElement(playButton, timeout: 10.0) {
        playButton.tap()
        TestHelpers.waitFor(0.5)
      }
    }
    
    When("I skip forward (\\d+) seconds") { args, _ in
      let skipButton = app.buttons[AccessibilityID.AudiobookPlayer.skipForwardButton]
      if skipButton.exists {
        skipButton.tap()
        TestHelpers.waitFor(0.5)
      }
    }
    
    When("I skip backward (\\d+) seconds") { args, _ in
      let skipButton = app.buttons[AccessibilityID.AudiobookPlayer.skipBackButton]
      if skipButton.exists {
        skipButton.tap()
        TestHelpers.waitFor(0.5)
      }
    }
    
    When("I set playback speed to \"(.*)\"") { args, _ in
      let speed = args![0] as! String
      let speedButton = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeedButton]
      if TestHelpers.waitForElement(speedButton, timeout: 5.0) {
        speedButton.tap()
        TestHelpers.waitFor(0.5)
      }
      
      let speedOption = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeed(speed)]
      if TestHelpers.waitForElement(speedOption, timeout: 3.0) {
        speedOption.tap()
      }
    }
    
    When("I open the table of contents") { _, _ in
      let tocButton = app.buttons[AccessibilityID.AudiobookPlayer.tocButton]
      if TestHelpers.waitForElement(tocButton, timeout: 5.0) {
        tocButton.tap()
        TestHelpers.waitFor(1.0)
      }
    }
    
    When("I select chapter (\\d+)") { args, _ in
      let chapterNum = Int(args![0] as! String)!
      let chapter = app.buttons[AccessibilityID.AudiobookPlayer.tocChapter(chapterNum - 1)]
      if TestHelpers.waitForElement(chapter, timeout: 5.0) {
        chapter.tap()
        TestHelpers.waitFor(1.0)
      }
    }
    
    Then("playback time should advance") { _, _ in
      let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
      guard timeLabel.waitForExistence(timeout: 5.0) else { XCTFail("Time label not found"); return }
      
      let time1 = TestHelpers.parseTimeLabel(timeLabel.label)
      TestHelpers.waitFor(5.0)
      let time2 = TestHelpers.parseTimeLabel(timeLabel.label)
      
      XCTAssertGreaterThan(time2, time1 + 3.0, "Playback time should advance")
    }
    
    Then("I should be on chapter (\\d+)") { args, _ in
      let expectedChapter = args![0] as! String
      let chapterLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
      if TestHelpers.waitForElement(chapterLabel, timeout: 5.0) {
        XCTAssertTrue(chapterLabel.label.lowercased().contains(expectedChapter))
      }
    }
  }
}
