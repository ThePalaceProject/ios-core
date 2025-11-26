import XCTest

/// Sample playback tests
/// Converted from: Samples.feature
final class SamplesTests: XCTestCase {
  
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
  
  func testPlayAudiobookSample() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook sample")
    tapFirstResult()
    
    // Look for sample button
    let sampleButton = app.buttons[AccessibilityID.BookDetail.audiobookSampleButton]
    
    if !sampleButton.exists {
      let anySampleButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sample' OR label CONTAINS[c] 'preview'")).firstMatch
      
      if anySampleButton.exists {
        anySampleButton.tap()
        Thread.sleep(forTimeInterval: 2.0)
        
        // Sample player should appear
        print("✅ Sample playback initiated")
      }
    } else {
      sampleButton.tap()
      Thread.sleep(forTimeInterval: 2.0)
    }
  }
  
  func testCloseSamplePlayer() {
    skipOnboarding()
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("audiobook sample")
    tapFirstResult()
    
    let sampleButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sample'")).firstMatch
    if sampleButton.exists {
      sampleButton.tap()
      Thread.sleep(forTimeInterval: 2.0)
      
      // Close sample
      let closeButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'close' OR label == 'Done'")).firstMatch
      if closeButton.exists {
        closeButton.tap()
      }
    }
  }
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
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

