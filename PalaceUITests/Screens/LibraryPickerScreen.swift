import XCTest

final class LibraryPickerScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var searchField: XCUIElement { app.searchFields.firstMatch }
  var libraryList: XCUIElement { app.tables.firstMatch }
  var firstLibraryCell: XCUIElement { app.cells.firstMatch }
  var cancelButton: XCUIElement { app.buttons["Cancel"] }
  var doneButton: XCUIElement { app.buttons[AccessibilityID.Common.doneButton] }
  var closeButton: XCUIElement { app.buttons[AccessibilityID.Common.closeButton] }

  // MARK: - Actions

  @discardableResult
  func searchForLibrary(_ name: String) -> LibraryPickerScreen {
    searchField.waitAndTap()
    searchField.typeText(name)
    return self
  }

  @discardableResult
  func selectFirstLibrary() -> LibraryPickerScreen {
    firstLibraryCell.waitAndTap()
    return self
  }

  @discardableResult
  func dismiss() -> SettingsScreen {
    if cancelButton.exists {
      cancelButton.tap()
    } else if closeButton.exists {
      closeButton.tap()
    } else if doneButton.exists {
      doneButton.tap()
    }
    return SettingsScreen(app: app)
  }

  // MARK: - Assertions

  func verifyLoaded() {
    let hasSearch = searchField.waitForExistence(timeout: 10)
    let hasList = libraryList.waitForExistence(timeout: 10)
    XCTAssertTrue(hasSearch || hasList, "Library picker should show search or library list")
  }

  func verifyHasLibraries() {
    XCTAssertTrue(firstLibraryCell.waitForExistence(timeout: 10), "Library list should have cells")
  }
}
