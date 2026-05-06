import XCTest

final class SettingsScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var settingsTab: XCUIElement { app.tabBars.buttons["Settings"] }
  var scrollView: XCUIElement { app.scrollViews[AccessibilityID.Settings.scrollView] }

  // Account section
  var accountSection: XCUIElement { app.otherElements[AccessibilityID.Settings.accountSection] }
  var libraryName: XCUIElement { app.staticTexts[AccessibilityID.Settings.libraryName] }
  var accountName: XCUIElement { app.staticTexts[AccessibilityID.Settings.accountName] }
  var signOutButton: XCUIElement { app.buttons[AccessibilityID.Settings.signOutButton] }
  var signInButton: XCUIElement { app.buttons[AccessibilityID.Settings.signInButton] }

  // Library management
  var manageLibrariesButton: XCUIElement { app.buttons[AccessibilityID.Settings.manageLibrariesButton] }
  var addLibraryButton: XCUIElement { app.buttons[AccessibilityID.Settings.addLibraryButton] }

  // App info
  var aboutPalaceButton: XCUIElement { app.buttons[AccessibilityID.Settings.aboutPalaceButton] }
  var privacyPolicyButton: XCUIElement { app.buttons[AccessibilityID.Settings.privacyPolicyButton] }
  var userAgreementButton: XCUIElement { app.buttons[AccessibilityID.Settings.userAgreementButton] }
  var softwareLicensesButton: XCUIElement { app.buttons[AccessibilityID.Settings.softwareLicensesButton] }

  // Advanced
  var advancedButton: XCUIElement { app.buttons[AccessibilityID.Settings.advancedButton] }

  // MARK: - Actions

  @discardableResult
  func navigate() -> SettingsScreen {
    settingsTab.waitAndTap()
    return self
  }

  @discardableResult
  func tapSignIn() -> SignInScreen {
    signInButton.waitAndTap()
    return SignInScreen(app: app)
  }

  @discardableResult
  func tapManageLibraries() -> LibraryPickerScreen {
    manageLibrariesButton.waitAndTap()
    return LibraryPickerScreen(app: app)
  }

  @discardableResult
  func tapAddLibrary() -> LibraryPickerScreen {
    addLibraryButton.waitAndTap()
    return LibraryPickerScreen(app: app)
  }

  @discardableResult
  func tapAboutPalace() -> SettingsScreen {
    aboutPalaceButton.waitAndTap()
    return self
  }

  // MARK: - Assertions

  func verifyLoaded() {
    XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab should exist")
  }

  func verifyAccountSection() {
    let hasAccount = accountSection.waitForExistence(timeout: 10)
      || libraryName.waitForExistence(timeout: 5)
      || signInButton.waitForExistence(timeout: 5)
    XCTAssertTrue(hasAccount, "Settings should show account section")
  }
}
