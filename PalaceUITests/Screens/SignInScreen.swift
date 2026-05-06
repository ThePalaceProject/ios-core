import XCTest

final class SignInScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  var barcodeField: XCUIElement { app.textFields[AccessibilityID.SignIn.barcodeField] }
  var pinField: XCUIElement { app.secureTextFields[AccessibilityID.SignIn.pinField] }
  var signInButton: XCUIElement { app.buttons[AccessibilityID.SignIn.signInButton] }
  var cancelButton: XCUIElement { app.buttons[AccessibilityID.SignIn.cancelButton] }
  var errorLabel: XCUIElement { app.staticTexts[AccessibilityID.SignIn.errorLabel] }

  // MARK: - Actions

  @discardableResult
  func typeBarcode(_ barcode: String) -> SignInScreen {
    barcodeField.waitAndTap()
    barcodeField.typeText(barcode)
    return self
  }

  @discardableResult
  func typePin(_ pin: String) -> SignInScreen {
    pinField.waitAndTap()
    pinField.typeText(pin)
    return self
  }

  @discardableResult
  func tapSignIn() -> SignInScreen {
    signInButton.waitAndTap()
    return self
  }

  @discardableResult
  func tapCancel() -> SettingsScreen {
    cancelButton.waitAndTap()
    return SettingsScreen(app: app)
  }

  @discardableResult
  func signIn(barcode: String, pin: String) -> SignInScreen {
    typeBarcode(barcode)
    typePin(pin)
    tapSignIn()
    return self
  }

  // MARK: - Assertions

  func verifyLoaded() {
    XCTAssertTrue(barcodeField.waitForExistence(timeout: 10), "Barcode field should be visible")
    XCTAssertTrue(pinField.waitForExistence(timeout: 5), "PIN field should be visible")
    XCTAssertTrue(signInButton.exists, "Sign in button should be visible")
  }

  func verifyError() {
    XCTAssertTrue(errorLabel.waitForExistence(timeout: 10), "Error label should be visible")
  }
}
