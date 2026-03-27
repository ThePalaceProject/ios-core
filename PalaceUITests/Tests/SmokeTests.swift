import XCTest

/// Smoke tests that verify basic app navigation and screen accessibility.
/// These tests do not require authentication or any pre-existing data.
final class SmokeTests: PalaceUITestCase {

  // MARK: - 1. App launches successfully

  func testAppLaunchesSuccessfully() {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
                  "App should launch into foreground state")
  }

  // MARK: - 2. Catalog tab shows content

  func testCatalogTabShowsContent() {
    let catalog = CatalogScreen(app: app)
    catalog.verifyLoaded()
  }

  // MARK: - 3. My Books tab is accessible

  func testMyBooksTabIsAccessible() {
    let myBooks = MyBooksScreen(app: app)
    myBooks.navigate()
    myBooks.verifyLoaded()
  }

  // MARK: - 4. Reservations tab is accessible

  func testReservationsTabIsAccessible() {
    let reservationsTab = app.tabBars.buttons["Reservations"]
    XCTAssertTrue(reservationsTab.waitForExistence(timeout: 10),
                  "Reservations tab should exist")
    reservationsTab.tap()
    // Verify we navigated - the tab should be selected
    XCTAssertTrue(reservationsTab.isSelected,
                  "Reservations tab should be selected after tapping")
  }

  // MARK: - 5. Settings tab is accessible

  func testSettingsTabIsAccessible() {
    let settings = SettingsScreen(app: app)
    settings.navigate()
    settings.verifyLoaded()
  }

  // MARK: - 6. Search screen opens from catalog

  func testSearchScreenOpensFromCatalog() {
    let catalog = CatalogScreen(app: app)
    // Wait for catalog to load first
    _ = catalog.catalogTab.waitForExistence(timeout: 10)

    let search = catalog.tapSearch()
    search.verifyLoaded()
  }

  // MARK: - 7. Book detail opens from catalog

  func testBookDetailOpensFromCatalog() {
    let catalog = CatalogScreen(app: app)
    // Wait for catalog content to load
    XCTAssertTrue(catalog.firstBookCell.waitForExistence(timeout: 20),
                  "Catalog should have at least one book cell")

    let detail = catalog.tapFirstBook()
    detail.verifyLoaded()
  }

  // MARK: - 8. Settings shows account section

  func testSettingsShowsAccountSection() {
    let settings = SettingsScreen(app: app)
    settings.navigate()
    settings.verifyAccountSection()
  }

  // MARK: - 9. Back navigation works from book detail

  func testBackNavigationFromBookDetail() {
    let catalog = CatalogScreen(app: app)
    // Wait for a book cell to be available
    XCTAssertTrue(catalog.firstBookCell.waitForExistence(timeout: 20),
                  "Catalog should have at least one book cell")

    let detail = catalog.tapFirstBook()
    detail.verifyLoaded()

    // Navigate back
    detail.tapBack()

    // Verify we are back on the catalog
    catalog.verifyLoaded()
  }

  // MARK: - 10. Tab switching works in sequence

  func testTabSwitchingWorksInSequence() {
    let catalogTab = app.tabBars.buttons["Catalog"]
    let myBooksTab = app.tabBars.buttons["My Books"]
    let reservationsTab = app.tabBars.buttons["Reservations"]
    let settingsTab = app.tabBars.buttons["Settings"]

    // All tabs should exist
    XCTAssertTrue(catalogTab.waitForExistence(timeout: 10))
    XCTAssertTrue(myBooksTab.exists)
    XCTAssertTrue(reservationsTab.exists)
    XCTAssertTrue(settingsTab.exists)

    // Switch through all tabs in sequence
    myBooksTab.tap()
    XCTAssertTrue(myBooksTab.isSelected, "My Books tab should be selected")

    reservationsTab.tap()
    XCTAssertTrue(reservationsTab.isSelected, "Reservations tab should be selected")

    settingsTab.tap()
    XCTAssertTrue(settingsTab.isSelected, "Settings tab should be selected")

    catalogTab.tap()
    XCTAssertTrue(catalogTab.isSelected, "Catalog tab should be selected after cycling")
  }
}
