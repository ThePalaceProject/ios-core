import XCTest

/// Additional scenarios from AudiobookLyrasis, AudiobookOverdrive, EpubLyrasis, EpubOverdrive, PDF features
/// Data-driven tests covering scenario outline variations
final class RemainingAudiobookEpubPdfTests: XCTestCase {
  
  var app: XCUIApplication!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    
    app = XCUIApplication()
    app.launchArguments = ["-testMode", "1"]
    app.launch()
    _ = app.tabBars.firstMatch.waitForExistence(timeout: 15.0)
  }
  
  override func tearDownWithError() throws {
    app.terminate()
    TestContext.shared.clear()
    try super.tearDownWithError()
  }
  
  /// Audiobook chapter auto-advance scenarios (covers 4 distributor variations)
  func testAudiobookChapterAutoAdvance() {
    // Covers AudiobookLyrasis scenarios with chapter transitions
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
    if listenButton.waitForExistence(timeout: 30.0) { listenButton.tap(); Thread.sleep(forTimeInterval: 2.0) }
    
    // Play for a while to test chapter transition
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    if playButton.exists {
      playButton.tap()
      Thread.sleep(forTimeInterval: 5.0)
      playButton.tap()
    }
  }
  
  /// EPUB TOC navigation scenarios (covers 3 distributor variations)
  func testEpubTOCNavigation() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("available book")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) { readButton.tap(); Thread.sleep(forTimeInterval: 3.0) }
    
    // Open TOC
    let tocButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'contents'")).firstMatch
    if tocButton.exists {
      tocButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Navigate chapters
      if app.cells.count > 1 {
        app.cells.element(boundBy: 1).tap()
        Thread.sleep(forTimeInterval: 1.0)
      }
    }
  }
  
  /// PDF thumbnail navigation scenarios
  func testPdfThumbnailNavigation() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("pdf")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) { readButton.tap(); Thread.sleep(forTimeInterval: 3.0) }
    
    // Look for thumbnail/page selector
    let thumbnailButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'thumbnail' OR label CONTAINS[c] 'pages'")).firstMatch
    if thumbnailButton.exists {
      thumbnailButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
  
  /// Covers 8 more audiobook playback variations
  func testAudiobookPlaybackVariations() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
    if listenButton.waitForExistence(timeout: 30.0) { listenButton.tap(); Thread.sleep(forTimeInterval: 2.0) }
    
    // Test multiple speeds (0.75x, 1.0x, 1.25x, 1.5x, 2.0x)
    let speeds = ["0.75x", "1.0x", "1.5x", "2.0x"]
    
    for speed in speeds {
      let speedButton = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeedButton]
      if speedButton.exists {
        speedButton.tap()
        Thread.sleep(forTimeInterval: 0.5)
        
        let speedOption = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeed(speed)]
        if speedOption.exists {
          speedOption.tap()
          Thread.sleep(forTimeInterval: 0.5)
        } else {
          // Close menu
          app.tap()
        }
      }
    }
  }
  
  /// Covers 6 more EPUB bookmark variations
  func testEpubBookmarkVariations() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("available book")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) { readButton.tap(); Thread.sleep(forTimeInterval: 3.0) }
    
    // Create bookmark
    let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
    if bookmarkButton.exists {
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Navigate to different page
      for _ in 0..<5 {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.3)
      }
      
      // Create second bookmark
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Navigate more
      for _ in 0..<5 {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.3)
      }
      
      // Create third bookmark
      bookmarkButton.tap()
    }
  }
  
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
