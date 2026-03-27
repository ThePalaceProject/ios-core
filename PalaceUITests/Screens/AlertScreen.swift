import XCTest

final class AlertScreen {
  let app: XCUIApplication

  init(app: XCUIApplication) {
    self.app = app
  }

  // MARK: - Elements

  /// Standard system alert
  var alert: XCUIElement { app.alerts.firstMatch }

  /// Action sheet
  var actionSheet: XCUIElement { app.sheets.firstMatch }

  /// Alert title
  var alertTitle: XCUIElement { alert.staticTexts.firstMatch }

  /// Error alert buttons (using AccessibilityID)
  var retryButton: XCUIElement { app.buttons[AccessibilityID.ErrorAlert.retryButton] }
  var cancelButton: XCUIElement { app.buttons[AccessibilityID.ErrorAlert.cancelButton] }
  var okButton: XCUIElement { app.buttons[AccessibilityID.ErrorAlert.okButton] }
  var viewErrorDetailsButton: XCUIElement { app.buttons[AccessibilityID.ErrorAlert.viewErrorDetailsButton] }

  // Specific error alerts
  var borrowErrorAlert: XCUIElement { app.otherElements[AccessibilityID.ErrorAlert.borrowErrorAlert] }
  var downloadErrorAlert: XCUIElement { app.otherElements[AccessibilityID.ErrorAlert.downloadErrorAlert] }
  var returnErrorAlert: XCUIElement { app.otherElements[AccessibilityID.ErrorAlert.returnErrorAlert] }

  // MARK: - Actions

  @discardableResult
  func tapOK() -> AlertScreen {
    // Try accessibility-identified OK first, then fall back to label-based
    if okButton.exists {
      okButton.tap()
    } else {
      alert.buttons["OK"].waitAndTap()
    }
    return self
  }

  @discardableResult
  func tapCancel() -> AlertScreen {
    if cancelButton.exists {
      cancelButton.tap()
    } else {
      alert.buttons["Cancel"].waitAndTap()
    }
    return self
  }

  @discardableResult
  func tapRetry() -> AlertScreen {
    retryButton.waitAndTap()
    return self
  }

  @discardableResult
  func dismissAlert() -> AlertScreen {
    if alert.exists {
      // Try OK, then Cancel, then first button
      if alert.buttons["OK"].exists {
        alert.buttons["OK"].tap()
      } else if alert.buttons["Cancel"].exists {
        alert.buttons["Cancel"].tap()
      } else {
        alert.buttons.firstMatch.tap()
      }
    }
    return self
  }

  @discardableResult
  func dismissActionSheet() -> AlertScreen {
    if actionSheet.exists {
      if actionSheet.buttons["Cancel"].exists {
        actionSheet.buttons["Cancel"].tap()
      } else {
        actionSheet.buttons.firstMatch.tap()
      }
    }
    return self
  }

  // MARK: - Assertions

  func verifyAlertPresent() {
    XCTAssertTrue(alert.waitForExistence(timeout: 10), "Alert should be present")
  }

  func verifyAlertDismissed() {
    XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "Alert should be dismissed")
  }

  func verifyActionSheetPresent() {
    XCTAssertTrue(actionSheet.waitForExistence(timeout: 10), "Action sheet should be present")
  }

  func verifyAlertTitle(contains text: String) {
    verifyAlertPresent()
    let titleExists = alert.staticTexts.containing(
      NSPredicate(format: "label CONTAINS[c] %@", text)
    ).firstMatch.exists
    XCTAssertTrue(titleExists, "Alert title should contain '\(text)'")
  }
}
