import XCTest

/// Base class for all Palace UI tests.
/// Provides common setup, teardown, and helper utilities.
class PalaceUITestCase: XCTestCase {

  var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += ["-UITesting"]
    app.launch()
  }

  override func tearDownWithError() throws {
    app = nil
    try super.tearDownWithError()
  }

  // MARK: - Wait Helpers

  /// Waits for an element to exist within the given timeout.
  @discardableResult
  func waitForElement(
    _ element: XCUIElement,
    timeout: TimeInterval = 10
  ) -> Bool {
    element.waitForExistence(timeout: timeout)
  }

  /// Waits for an element to become hittable.
  @discardableResult
  func waitForHittable(
    _ element: XCUIElement,
    timeout: TimeInterval = 10
  ) -> Bool {
    let predicate = NSPredicate(format: "isHittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
    return result == .completed
  }

  // MARK: - Tab Navigation

  func tapCatalogTab() {
    app.tabBars.buttons["Catalog"].tap()
  }

  func tapMyBooksTab() {
    app.tabBars.buttons["My Books"].tap()
  }

  func tapReservationsTab() {
    app.tabBars.buttons["Reservations"].tap()
  }

  func tapSettingsTab() {
    app.tabBars.buttons["Settings"].tap()
  }

  // MARK: - Catalog Helpers

  /// Waits for the catalog to finish loading by waiting for the loading indicator
  /// to disappear or for content to appear.
  func waitForCatalogToLoad(timeout: TimeInterval = 15) {
    // Either the scroll view or some collection/table content should appear
    let scrollView = app.scrollViews[AccessibilityID.Catalog.scrollView]
    let collectionView = app.collectionViews.firstMatch
    let tableView = app.tables.firstMatch

    let predicate = NSPredicate(format:
      "exists == true"
    )

    // Wait for any content container to appear
    let scrollExp = XCTNSPredicateExpectation(predicate: predicate, object: scrollView)
    let collectionExp = XCTNSPredicateExpectation(predicate: predicate, object: collectionView)
    let tableExp = XCTNSPredicateExpectation(predicate: predicate, object: tableView)

    // Any one of these is sufficient
    _ = XCTWaiter().wait(for: [scrollExp, collectionExp, tableExp], timeout: timeout)
  }
}
