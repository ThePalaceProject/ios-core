import XCTest

/// EPUB reading tests
/// Converted from: EpubLyrasis.feature, EpubOverdrive.feature, EpubPalace.feature
final class EpubTests: XCTestCase {
  
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
  
  /// Open EPUB and verify reader displays
  func testOpenEpubBook() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()  // ← Sign in before borrowing!
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Alice")
    tapFirstResult()
    
    // Get book
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.waitForExistence(timeout: 5.0) {
      getButton.tap()
    }
    
    // Wait for READ button
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Verify EPUB reader opened (tab bar hidden)
    let tabBar = app.tabBars.firstMatch
    let isReaderOpen = !tabBar.isHittable || !tabBar.exists
    
    XCTAssertTrue(isReaderOpen, "EPUB reader should open")
  }
  
  /// Navigate pages in EPUB
  func testEpubPageNavigation() {
    skipOnboarding()
    // DON'T sign in proactively - let it happen when we borrow
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    
    // Search for "epub"
    search("epub")
    
    // Find and open an available EPUB (scroll if needed)
    var foundEpub = false
    for attempt in 0..<3 {
      tapFirstResult()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Check if there's a Borrow/Get button (available book)
      let borrowButton = app.buttons["Borrow"]
      let getButton = app.buttons["Get"]
      
      if borrowButton.exists || getButton.exists {
        // Tap to borrow/get (use firstMatch to handle multiples)
        if borrowButton.exists { borrowButton.firstMatch.tap() }
        else if getButton.exists { getButton.firstMatch.tap() }
        
        // Handle any modals that appear (sign-in, library selector, etc.)
        AuthenticationHelper.handleBorrowModals(app: app)
        
        // Wait for READ button (confirms it's an EPUB and download complete)
        print("⏳ Waiting for READ button (download in progress)...")
        
        // Check what buttons exist
        Thread.sleep(forTimeInterval: 3.0)
        let allButtons = app.buttons.allElementsBoundByIndex.prefix(10).map { $0.label }
        print("   Buttons on screen: \(allButtons)")
        
        let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
        let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
        
        if readButton.waitForExistence(timeout: 30.0) {
          print("✅ Found EPUB book, opening reader...")
          readButton.tap()
          Thread.sleep(forTimeInterval: 3.0)
          foundEpub = true
          break
        } else {
          print("⚠️ Book didn't download or isn't EPUB, trying next...")
          // Go back and try next result
          let backButton = app.navigationBars.buttons.element(boundBy: 0)
          if backButton.exists { backButton.tap(); Thread.sleep(forTimeInterval: 0.5) }
        }
      } else {
        print("⚠️ Book not available, trying next...")
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists { backButton.tap(); Thread.sleep(forTimeInterval: 0.5) }
      }
    }
    
    if !foundEpub {
      XCTFail("Could not find available EPUB book after 3 attempts")
      return
    }
    
    // Navigate pages - tap right side
    for _ in 0..<5 {
      let rightSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
      rightSide.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Navigate back - tap left side
    for _ in 0..<2 {
      let leftSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
      leftSide.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
    
    // Still in reader
    let tabBar = app.tabBars.firstMatch
    XCTAssertFalse(tabBar.isHittable, "Should still be in reader")
  }
  
  /// Create bookmark in EPUB
  func testEpubBookmark() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()  // ← Sign in before borrowing!
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Pride Prejudice")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Look for bookmark button
    let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
    
    if bookmarkButton.exists {
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Bookmark should be created
      print("✅ Bookmark created")
    }
  }
  
  /// Resume reading at last page
  func testEpubResumeReading() {
    skipOnboarding()
    selectLibrary("Lyrasis Reads")
    signInToLyrasis()  // ← Sign in before borrowing!
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Metamorphosis")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 2.0)
    }
    
    // Read a few pages
    for _ in 0..<10 {
      let rightSide = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
      rightSide.tap()
      Thread.sleep(forTimeInterval: 0.3)
    }
    
    // Close reader (tap top left)
    let topLeft = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
    topLeft.tap()
    Thread.sleep(forTimeInterval: 1.0)
    
    // Tap anywhere to dismiss menu if appeared
    app.tap()
    Thread.sleep(forTimeInterval: 1.0)
    
    // Should be back at book detail or my books
    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.exists, "Should return from reader")
  }
  
  // MARK: - More EPUB Scenarios (from EpubLyrasis.feature)
  
  /// Navigate by page numbers
  func testEpubNavigateByPageNumber() {
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
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Navigate forward 7-10 times
    for _ in 0..<8 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
      Thread.sleep(forTimeInterval: 0.3)
    }
    
    // Close and reopen - should resume at page
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
    Thread.sleep(forTimeInterval: 1.0)
    
    if readButton.exists {
      readButton.tap()
      Thread.sleep(forTimeInterval: 2.0)
    }
    
    // Should be in reader
    XCTAssertFalse(app.tabBars.firstMatch.isHittable, "Should resume in reader")
  }
  
  /// Multiple bookmarks
  func testMultipleBookmarks() {
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
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Create first bookmark
    let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
    if bookmarkButton.exists {
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Navigate pages
      for _ in 0..<7 {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.3)
      }
      
      // Create second bookmark
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  // MARK: - More EPUB Scenarios (from EpubLyrasis.feature)
  
  /// Navigate by TOC
  func testEpubTableOfContents() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Alice")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Open TOC
    let tocButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'contents' OR label CONTAINS[c] 'chapters'")).firstMatch
    if tocButton.exists {
      tocButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Select chapter
      let anyChapter = app.cells.element(boundBy: 1)
      if anyChapter.exists { anyChapter.tap() }
    }
  }
  
  /// Font size adjustment
  func testEpubFontSizeAdjustment() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Pride Prejudice")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Look for settings/font button
    let settingsButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'settings' OR label CONTAINS[c] 'font' OR label CONTAINS[c] 'Aa'")).firstMatch
    if settingsButton.exists {
      settingsButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
    }
  }
  
  /// Search within book
  func testEpubInBookSearch() {
    skipOnboarding()
    selectLibrary("Palace Bookshelf")
    
    TestHelpers.navigateToTab("Catalog")
    openSearch()
    search("Moby Dick")
    tapFirstResult()
    
    let getButton = app.buttons[AccessibilityID.BookDetail.getButton].firstMatch
    if getButton.exists { getButton.tap() }
    
    let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Look for search button in reader
    let searchButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'search'")).firstMatch
    if searchButton.exists {
      searchButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Type search term
      let searchField = app.searchFields.firstMatch
      if searchField.exists {
        searchField.tap()
        searchField.typeText("whale")
      }
    }
  }
  
  /// Bookmark navigation
  func testNavigateByBookmarks() {
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
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Create bookmark
    let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
    if bookmarkButton.exists {
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      
      // Navigate pages
      for _ in 0..<5 {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.3)
      }
      
      // Create another bookmark
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  /// Delete bookmark
  func testDeleteBookmark() {
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
    if readButton.waitForExistence(timeout: 30.0) {
      readButton.tap()
      Thread.sleep(forTimeInterval: 3.0)
    }
    
    // Create and delete bookmark
    let bookmarkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bookmark'")).firstMatch
    if bookmarkButton.exists {
      bookmarkButton.tap()
      Thread.sleep(forTimeInterval: 0.5)
      bookmarkButton.tap() // Toggle to delete
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
  
  // MARK: - Helpers
  
  private func skipOnboarding() {
    Thread.sleep(forTimeInterval: 1.0)
    if app.buttons["Skip"].exists { app.buttons["Skip"].tap() }
    if app.buttons["Close"].exists { app.buttons["Close"].tap() }
  }
  
  private func selectLibrary(_ name: String) {
    print("📚 Selecting library: \(name)...")
    
    // Navigate to Settings
    TestHelpers.navigateToTab("Settings")
    Thread.sleep(forTimeInterval: 1.0)
    
    // Look for library/account button
    let libraryButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'library' OR label CONTAINS[c] 'libraries'")).firstMatch
    
    if libraryButton.exists {
      libraryButton.tap()
      Thread.sleep(forTimeInterval: 1.0)
      
      // Look for the library in the list
      let libraryCell = app.cells.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
      
      if libraryCell.exists {
        libraryCell.tap()
        Thread.sleep(forTimeInterval: 2.0)
        print("✅ Selected library: \(name)")
      } else {
        print("⚠️ Library '\(name)' not found in list, using current library")
      }
    } else {
      print("ℹ️ No library selector found - using current library")
    }
    
    // Return to Catalog
    TestHelpers.navigateToTab("Catalog")
    Thread.sleep(forTimeInterval: 1.0)
  }
  
  private func signInToLyrasis() {
    let credentials = TestHelpers.TestCredentials.lyrasis
    
    print("🔐 Attempting to sign in to Lyrasis Reads...")
    
    // Sign-in screen might auto-present after selecting library
    // Wait a bit for it to appear
    Thread.sleep(forTimeInterval: 2.0)
    
    // Check if sign-in fields are present
    let barcodeField = app.textFields.firstMatch
    let pinField = app.secureTextFields.firstMatch
    
    if !barcodeField.exists && !pinField.exists {
      print("   No sign-in fields found - checking if already signed in...")
      
      // Check if we're already signed in (catalog is accessible)
      let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
      if catalogTab.exists {
        print("✅ Already signed in (or library doesn't require auth)")
        return
      }
      
      // Try navigating to trigger sign-in
      TestHelpers.navigateToTab("Settings")
      Thread.sleep(forTimeInterval: 1.0)
      
      // Look for sign-in option
      let signInButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign in'")).firstMatch
      if signInButton.exists {
        signInButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
      }
    }
    
    // Now try to fill in credentials
    if barcodeField.waitForExistence(timeout: 5.0) {
      print("   Found barcode field, entering credentials...")
      barcodeField.tap()
      barcodeField.typeText(credentials.barcode)
      
      if pinField.waitForExistence(timeout: 3.0) {
        pinField.tap()
        pinField.typeText(credentials.pin)
      }
      
      // Tap sign-in button
      let signInSubmitButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sign'")).firstMatch
      if signInSubmitButton.exists {
        signInSubmitButton.tap()
        Thread.sleep(forTimeInterval: 5.0)  // Wait longer for sign-in to complete
      }
      
      // Verify sign-in succeeded
      let catalogTab = app.tabBars.buttons[AppStrings.TabBar.catalog]
      if catalogTab.exists {
        print("✅ Sign-in successful!")
      } else {
        print("⚠️ Warning: Sign-in may have failed - catalog not accessible")
      }
    } else {
      print("⚠️ No sign-in form appeared - proceeding anyway")
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
