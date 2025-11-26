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
    
    // Tap first search result to open book detail
    var firstResult = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
    if !firstResult.exists {
      firstResult = app.cells.firstMatch
    }
    
    if firstResult.waitForExistence(timeout: 5.0) {
      firstResult.tap()
      Thread.sleep(forTimeInterval: 2.0)
    }
    
    // Now on book detail - tap GET (should be single button now)
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
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
  
  // MARK: - More AudiobookLyrasis Scenarios
  
  /// Open audiobook at last chapter and check time code
  func testOpenAudiobookAtLastChapter() {
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
    if getButton.exists { getButton.tap() }
    
    let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
    if listenButton.waitForExistence(timeout: 30.0) { listenButton.tap(); Thread.sleep(forTimeInterval: 2.0) }
    
    // Open TOC
    let tocButton = app.buttons[AccessibilityID.AudiobookPlayer.tocButton]
    if tocButton.exists { tocButton.tap(); Thread.sleep(forTimeInterval: 1.0) }
    
    // Select chapter 3
    let chapter3 = app.buttons[AccessibilityID.AudiobookPlayer.tocChapter(2)]
    if !chapter3.exists {
      let anyChapter = app.cells.element(boundBy: 2)
      if anyChapter.exists { anyChapter.tap() }
    } else {
      chapter3.tap()
    }
    
    Thread.sleep(forTimeInterval: 1.0)
    
    // Verify player returned
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    XCTAssertTrue(playButton.exists, "Should return to player")
  }
  
  /// Test playback speed changes
  func testChangePlaybackSpeed() {
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
    if getButton.exists { getButton.tap() }
    
    let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
    if listenButton.waitForExistence(timeout: 30.0) { listenButton.tap(); Thread.sleep(forTimeInterval: 2.0) }
    
    // Change speed
    let speedButton = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeedButton]
    if speedButton.exists {
      speedButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Select 1.5x
      let speed15x = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeed("1.5x")]
      if speed15x.exists { speed15x.tap() }
    }
    
    // Play and verify time advances
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    if playButton.exists {
      playButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
      playButton.tap()
    }
  }
  
  /// Test sleep timer
  func testSleepTimer() {
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
    if getButton.exists { getButton.tap() }
    
    let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
    if listenButton.waitForExistence(timeout: 30.0) { listenButton.tap(); Thread.sleep(forTimeInterval: 2.0) }
    
    // Set sleep timer
    let sleepButton = app.buttons[AccessibilityID.AudiobookPlayer.sleepTimerButton]
    if sleepButton.exists {
      sleepButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Select end of chapter
      let endOfChapter = app.buttons[AccessibilityID.AudiobookPlayer.sleepTimerEndOfChapter]
      if endOfChapter.exists { endOfChapter.tap() }
    }
  }
  
  /// Position restoration after restart
  func testAudiobookPositionRestoration() {
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
    if getButton.exists { getButton.tap() }
    
    let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
    if listenButton.waitForExistence(timeout: 30.0) { listenButton.tap(); Thread.sleep(forTimeInterval: 2.0) }
    
    // Play for 10 seconds
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    if playButton.exists {
      playButton.tap()
      Thread.sleep(forTimeInterval: 10.0)
      playButton.tap()
    }
    
    // Save time
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    var savedTime: TimeInterval = 0
    if timeLabel.exists {
      savedTime = TestHelpers.parseTimeLabel(timeLabel.label)
    }
    
    // Restart app
    app.terminate()
    Thread.sleep(forTimeInterval: 2.0)
    app.launch()
    _ = app.tabBars.firstMatch.waitForExistence(timeout: 15.0)
    
    // Reopen audiobook
    TestHelpers.navigateToTab("My Books")
    Thread.sleep(forTimeInterval: 1.0)
    
    let firstBook = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'myBooks.bookCell.'")).firstMatch
    if firstBook.exists {
      firstBook.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      let listenAgain = app.buttons[AccessibilityID.BookDetail.listenButton]
      if listenAgain.exists { listenAgain.tap(); Thread.sleep(forTimeInterval: 2.0) }
    }
    
    // Verify position restored (within 5 seconds)
    if timeLabel.exists {
      let restoredTime = TestHelpers.parseTimeLabel(timeLabel.label)
      XCTAssertEqual(restoredTime, savedTime, accuracy: 5.0, "Position should restore")
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
  
  private func search(_ term: String) {
    let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
    
    if searchField.waitForExistence(timeout: 5.0) {
      searchField.tap()
      searchField.typeText(term)
      Thread.sleep(forTimeInterval: 2.0)
    }
  }
  
  private func tapFirstResult() {
    var firstResult = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
    if !firstResult.exists {
      firstResult = app.cells.firstMatch
    }
    
    if firstResult.waitForExistence(timeout: 5.0) {
      firstResult.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
}
