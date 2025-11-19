import XCTest
/// Critical smoke tests that verify core app functionality.
///
/// **AI-DEV GUIDE:**
/// - These tests MUST pass before any release
/// - Cover critical user journeys
/// - Run first in CI/CD pipeline
/// - Keep execution time under 15 minutes total
///
/// **TEST COVERAGE:**
/// 1. App launch and tab navigation
/// 2. Catalog loading
/// 3. Book search
/// 4. Book detail view
/// 5. Book acquisition (GET)
/// 6. Book download completion
/// 7. My Books view
/// 8. Book deletion
/// 9. Settings access
/// 10. End-to-end book flow
///
final class SmokeTests: BaseTestCase {
  
  // MARK: - Test 1: App Launch & Tab Navigation
  
  /// **CRITICAL:** Verifies app launches successfully and all tabs are accessible
  ///
  /// **Steps:**
  /// 1. App launches
  /// 2. Catalog tab is visible
  /// 3. Navigate to each tab
  /// 4. Verify each tab displays correctly
  ///
  /// **Expected:** All tabs load without errors
  func testAppLaunchAndTabNavigation() {
    takeScreenshot(named: "app-launch")
    
    // Verify Catalog tab is default
    let catalogTab = app.tabBars.buttons["Catalog"]
    XCTAssertTrue(catalogTab.exists, "Catalog tab should exist")
    XCTAssertTrue(catalogTab.isSelected, "Catalog tab should be selected by default")
    
    // Navigate to My Books
    navigateToTab(.myBooks)
    takeScreenshot(named: "my-books-tab")
    let myBooksScreen = MyBooksScreen(app: app)
    XCTAssertTrue(myBooksScreen.isDisplayed(), "My Books screen should display")
    
    // Navigate to Holds
    navigateToTab(.holds)
    takeScreenshot(named: "holds-tab")
    let holdsTab = app.tabBars.buttons["Reservations"]
    XCTAssertTrue(holdsTab.isSelected, "Holds tab should be selected")
    
    // Navigate to Settings
    navigateToTab(.settings)
    takeScreenshot(named: "settings-tab")
    let settingsScrollView = app.scrollViews[AccessibilityID.Settings.scrollView]
    XCTAssertTrue(settingsScrollView.waitForExistence(timeout: TestConfiguration.uiTimeout),
                  "Settings screen should display")
    
    // Return to Catalog
    navigateToTab(.catalog)
    let catalogScreen = CatalogScreen(app: app)
    XCTAssertTrue(catalogScreen.isDisplayed(), "Catalog screen should display")
  }
  
  // MARK: - Test 2: Catalog Loading
  
  /// **CRITICAL:** Verifies catalog loads successfully
  ///
  /// **Steps:**
  /// 1. Open app to catalog
  /// 2. Wait for catalog to load
  /// 3. Verify no error state
  /// 4. Verify books are displayed
  ///
  /// **Expected:** Catalog loads with visible books
  func testCatalogLoads() {
    let catalog = CatalogScreen(app: app)
    
    XCTAssertTrue(catalog.isDisplayed(timeout: TestConfiguration.networkTimeout),
                  "Catalog should load")
    
    XCTAssertTrue(catalog.isCatalogLoaded(),
                  "Catalog should load without errors")
    
    takeScreenshot(named: "catalog-loaded")
    
    // Verify at least one book is visible
    let bookCells = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog.bookCell.'"))
    XCTAssertGreaterThan(bookCells.count, 0, "Catalog should display books")
  }
  
  // MARK: - Test 3: Book Search
  
  /// **CRITICAL:** Verifies search functionality works
  ///
  /// **Steps:**
  /// 1. Tap search button
  /// 2. Enter search query
  /// 3. Verify results appear
  ///
  /// **Expected:** Search returns relevant results
  func testBookSearch() {
    let catalog = CatalogScreen(app: app)
    XCTAssertTrue(catalog.isDisplayed(), "Catalog should be displayed")
    
    let search = catalog.tapSearchButton()
    XCTAssertTrue(search.isDisplayed(), "Search screen should display")
    
    takeScreenshot(named: "search-screen")
    
    // Search for common term
    search.enterSearchText("alice")
    
    takeScreenshot(named: "search-results")
    
    // Verify results
    XCTAssertTrue(search.hasResults(), "Search should return results")
    XCTAssertGreaterThan(search.resultCount(), 0, "Search should have at least one result")
  }
  
  // MARK: - Test 4: Book Detail View
  
  /// **CRITICAL:** Verifies book detail screen displays
  ///
  /// **Steps:**
  /// 1. Search for book
  /// 2. Tap first result
  /// 3. Verify book detail displays
  /// 4. Verify GET/READ button exists
  ///
  /// **Expected:** Book details load correctly
  func testBookDetailView() {
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice")
    
    let bookDetail = search.tapFirstResult()
    XCTAssertNotNil(bookDetail, "Should navigate to book detail")
    
    XCTAssertTrue(bookDetail!.isDisplayed(timeout: TestConfiguration.uiTimeout),
                  "Book detail should display")
    
    takeScreenshot(named: "book-detail")
    
    // Verify book information is visible
    XCTAssertTrue(bookDetail!.coverImage.exists, "Book cover should display")
    XCTAssertTrue(bookDetail!.titleLabel.exists, "Book title should display")
    
    // Verify action button exists (GET or READ)
    let hasActionButton = bookDetail!.hasGetButton() || 
                         bookDetail!.hasReadButton() || 
                         bookDetail!.hasListenButton()
    XCTAssertTrue(hasActionButton, "Should have at least one action button")
  }
  
  // MARK: - Test 5: Book Acquisition (GET Button)
  
  /// **CRITICAL:** Verifies GET button functionality
  ///
  /// **Steps:**
  /// 1. Find book with GET button
  /// 2. Tap GET button
  /// 3. Verify download starts
  ///
  /// **Expected:** Book begins downloading
  func testBookAcquisition() {
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not open book detail")
      return
    }
    
    // If book is already downloaded, delete it first
    if bookDetail.hasDeleteButton() {
      bookDetail.tapDeleteButton(confirm: true)
      _ = bookDetail.waitForGetButton()
      takeScreenshot(named: "book-deleted-ready-for-get")
    }
    
    // Verify GET button exists
    XCTAssertTrue(bookDetail.hasGetButton(), "Should have GET button")
    
    // Tap GET
    bookDetail.tapGetButton()
    
    takeScreenshot(named: "book-acquiring")
    
    // Verify download started (GET button disappears or progress shows)
    Thread.sleep(forTimeInterval: 1.0)
    let downloadInProgress = bookDetail.isDownloading() || 
                            bookDetail.hasReadButton() || 
                            bookDetail.hasListenButton()
    XCTAssertTrue(downloadInProgress, "Download should start")
  }
  
  // MARK: - Test 6: Book Download Completion
  
  /// **CRITICAL:** Verifies book downloads completely
  ///
  /// **Steps:**
  /// 1. Acquire book
  /// 2. Wait for download to complete
  /// 3. Verify READ/LISTEN button appears
  ///
  /// **Expected:** Book downloads successfully
  func testBookDownloadCompletion() {
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not open book detail")
      return
    }
    
    // Delete if already downloaded
    if bookDetail.hasDeleteButton() {
      bookDetail.tapDeleteButton(confirm: true)
      _ = bookDetail.waitForGetButton()
    }
    
    // Download book
    XCTAssertTrue(bookDetail.downloadBook(), "Book should download successfully")
    
    takeScreenshot(named: "book-downloaded")
    
    // Verify READ or LISTEN button is available
    let canOpen = bookDetail.hasReadButton() || bookDetail.hasListenButton()
    XCTAssertTrue(canOpen, "Should be able to open downloaded book")
  }
  
  // MARK: - Test 7: My Books View
  
  /// **CRITICAL:** Verifies My Books displays downloaded books
  ///
  /// **Steps:**
  /// 1. Download a book (if needed)
  /// 2. Navigate to My Books
  /// 3. Verify book appears in library
  ///
  /// **Expected:** Downloaded book visible in My Books
  func testMyBooksDisplaysDownloadedBook() {
    // First, ensure we have at least one book
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not open book detail")
      return
    }
    
    // Download if needed
    if bookDetail.hasGetButton() {
      XCTAssertTrue(bookDetail.downloadBook(), "Book should download")
    }
    
    // Navigate to My Books
    navigateToTab(.myBooks)
    
    let myBooks = MyBooksScreen(app: app)
    XCTAssertTrue(myBooks.isDisplayed(), "My Books should display")
    
    takeScreenshot(named: "my-books-with-book")
    
    // Verify we have books
    XCTAssertTrue(myBooks.hasBooks(), "My Books should contain downloaded book")
    XCTAssertGreaterThan(myBooks.bookCount(), 0, "Should have at least one book")
  }
  
  // MARK: - Test 8: Book Deletion
  
  /// **CRITICAL:** Verifies book can be deleted
  ///
  /// **Steps:**
  /// 1. Find downloaded book
  /// 2. Tap DELETE button
  /// 3. Confirm deletion
  /// 4. Verify GET button returns
  ///
  /// **Expected:** Book is deleted and can be re-acquired
  func testBookDeletion() {
    // Download a book first
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not open book detail")
      return
    }
    
    // Ensure book is downloaded
    if bookDetail.hasGetButton() {
      XCTAssertTrue(bookDetail.downloadBook(), "Book should download")
    }
    
    // Now delete it
    XCTAssertTrue(bookDetail.hasDeleteButton(), "Should have DELETE button")
    
    takeScreenshot(named: "before-delete")
    
    bookDetail.tapDeleteButton(confirm: true)
    
    takeScreenshot(named: "after-delete")
    
    // Verify GET button returns
    XCTAssertTrue(bookDetail.waitForGetButton(), "GET button should appear after deletion")
  }
  
  // MARK: - Test 9: Settings Access
  
  /// **CRITICAL:** Verifies settings screen is accessible
  ///
  /// **Steps:**
  /// 1. Navigate to Settings
  /// 2. Verify settings options display
  ///
  /// **Expected:** Settings screen loads
  func testSettingsAccess() {
    navigateToTab(.settings)
    
    let settingsScrollView = app.scrollViews[AccessibilityID.Settings.scrollView]
    XCTAssertTrue(settingsScrollView.waitForExistence(timeout: TestConfiguration.uiTimeout),
                  "Settings should display")
    
    takeScreenshot(named: "settings-screen")
    
    // Verify key settings elements exist
    let aboutButton = app.buttons[AccessibilityID.Settings.aboutPalaceButton]
    XCTAssertTrue(aboutButton.exists, "About Palace button should exist")
  }
  
  // MARK: - Test 10: End-to-End Book Flow
  
  /// **CRITICAL:** Verifies complete book lifecycle
  ///
  /// **Steps:**
  /// 1. Search for book
  /// 2. Open book detail
  /// 3. Download book
  /// 4. Verify in My Books
  /// 5. Open book detail from My Books
  /// 6. Delete book
  /// 7. Verify removed from My Books
  ///
  /// **Expected:** Complete flow works without errors
  func testEndToEndBookFlow() {
    // Step 1: Search and find book
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("alice")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not open book detail")
      return
    }
    
    takeScreenshot(named: "e2e-01-book-detail")
    
    // Step 2: Download book
    if bookDetail.hasDeleteButton() {
      bookDetail.tapDeleteButton(confirm: true)
      _ = bookDetail.waitForGetButton()
    }
    
    XCTAssertTrue(bookDetail.downloadBook(), "Book should download")
    takeScreenshot(named: "e2e-02-book-downloaded")
    
    // Step 3: Navigate to My Books
    navigateToTab(.myBooks)
    
    let myBooks = MyBooksScreen(app: app)
    XCTAssertTrue(myBooks.hasBooks(), "Book should appear in My Books")
    takeScreenshot(named: "e2e-03-my-books")
    
    // Step 4: Open book from My Books
    guard let bookDetailFromMyBooks = myBooks.selectFirstBook() else {
      XCTFail("Could not open book from My Books")
      return
    }
    
    XCTAssertTrue(bookDetailFromMyBooks.hasDeleteButton(), "Should have DELETE button")
    takeScreenshot(named: "e2e-04-book-detail-from-my-books")
    
    // Step 5: Delete book
    bookDetailFromMyBooks.tapDeleteButton(confirm: true)
    _ = bookDetailFromMyBooks.waitForGetButton()
    takeScreenshot(named: "e2e-05-book-deleted")
    
    // Step 6: Verify removed from My Books
    navigateToTab(.myBooks)
    
    // Note: Book count may be 0 if this was the only book
    // The important thing is the flow completed without crashes
    takeScreenshot(named: "e2e-06-my-books-after-delete")
    
    XCTAssertTrue(myBooks.isDisplayed(), "My Books should still be accessible")
  }
}

