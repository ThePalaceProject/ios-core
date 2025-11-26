import XCTest

/// Audiobook playback tests
/// Converted from: AudiobookLyrasis.feature
final class AudiobookTests: XCTestCase {
  
  var app: XCUIApplication!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    
    app = XCUIApplication()
    app.launchArguments = ["-testMode", "1"]
    app.launch()
    _ = app.tabBars.firstMatch.waitForExistence(timeout: 15.0)
    
    // Background from AudiobookLyrasis.feature
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
  }
  
  override func tearDownWithError() throws {
    app.terminate()
    TestContext.shared.clear()
    try super.tearDownWithError()
  }
  
  // MARK: - From AudiobookLyrasis.feature
  
  /// Scenario: Navigate by Audiobook (line 63)
  func testNavigateByAudiobook() {
    // Search for audiobook
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    if searchField.waitForExistence(timeout: 5.0) {
      searchField.tap()
      searchField.typeText("audiobook")
      Thread.sleep(forTimeInterval: 2.0)
    }
    
    // Open first audiobook
    let firstBook = app.otherElements.firstMatch
    if firstBook.waitForExistence(timeout: 5.0) {
      firstBook.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
    
    // Get book (use firstMatch - search results have multiple GET buttons)
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.waitForExistence(timeout: 5.0) {
      getButton.tap()
    }
    
    // Wait for download
    let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
    if listenButton.waitForExistence(timeout: 30.0) {
      listenButton.tap()
      Thread.sleep(forTimeInterval: 2.0)
    }
    
    // Verify audio player opened
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    XCTAssertTrue(playButton.waitForExistence(timeout: 10.0), "Audio player should open")
    
    // Save initial time
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    if timeLabel.waitForExistence(timeout: 5.0) {
      let time1 = TestHelpers.parseTimeLabel(timeLabel.label)
      TestContext.shared.save(time1, forKey: "timeAhead")
      
      // Play
      playButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
      
      // Pause
      playButton.tap()
      
      // Save time after playing
      let time2 = TestHelpers.parseTimeLabel(timeLabel.label)
      TestContext.shared.save(time2, forKey: "timeAfter")
      
      // Skip forward 30 seconds
      let skipButton = app.buttons[AccessibilityID.AudiobookPlayer.skipForwardButton]
      if skipButton.exists {
        skipButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
      }
      
      // Verify time advanced
      let time3 = TestHelpers.parseTimeLabel(timeLabel.label)
      XCTAssertGreaterThan(time3, time2, "Time should advance after skip")
      
      // Skip backward
      let skipBackButton = app.buttons[AccessibilityID.AudiobookPlayer.skipBackButton]
      if skipBackButton.exists {
        skipBackButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
      }
      
      // Verify time went back
      let time4 = TestHelpers.parseTimeLabel(timeLabel.label)
      XCTAssertLessThan(time4, time3, "Time should go back after skip backward")
    }
  }
  
  // MARK: - Helpers
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
  
  private func selectLibrary(_ name: String) {
    Thread.sleep(forTimeInterval: 1.0)
  }
  
  private func signInToLyrasis() {
    let credentials = TestHelpers.TestCredentials.lyrasis
    Thread.sleep(forTimeInterval: 1.0)
    
    let barcodeField = app.textFields.firstMatch
    if barcodeField.waitForExistence(timeout: 5.0) {
      barcodeField.tap()
      barcodeField.typeText(credentials.barcode)
    }
    
    let pinField = app.secureTextFields.firstMatch
    if pinField.waitForExistence(timeout: 3.0) {
      pinField.tap()
      pinField.typeText(credentials.pin)
    }
    
    let signInButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign'")).firstMatch
    if signInButton.exists {
      signInButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
  }
  
  private func openSearch() {
    let searchButton = app.buttons[AccessibilityID.Catalog.searchButton]
    if searchButton.exists {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
}

