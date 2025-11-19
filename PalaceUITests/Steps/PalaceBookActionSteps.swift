import Foundation
import Cucumberish
import XCTest

class PalaceBookActionSteps {
  static func setup() {
    let app = TestHelpers.app
    
    When("I tap the (GET|READ|LISTEN|DELETE|RESERVE|CANCEL) button") { args, _ in
      let buttonName = args![0] as! String
      let buttonID: String
      
      switch buttonName {
      case "GET": buttonID = AccessibilityID.BookDetail.getButton
      case "READ": buttonID = AccessibilityID.BookDetail.readButton
      case "LISTEN": buttonID = AccessibilityID.BookDetail.listenButton
      case "DELETE": buttonID = AccessibilityID.BookDetail.deleteButton
      case "RESERVE": buttonID = AccessibilityID.BookDetail.reserveButton
      case "CANCEL": buttonID = AccessibilityID.BookDetail.cancelButton
      default: XCTFail("Unknown button: \(buttonName)"); return
      }
      
      let button = app.buttons[buttonID]
      if TestHelpers.waitForElement(button, timeout: 10.0) {
        button.tap()
        TestHelpers.waitFor(0.5)
      }
    }
    
    When("I confirm deletion") { _, _ in
      let halfSheet = app.sheets[AccessibilityID.BookDetail.halfSheet]
      if halfSheet.waitForExistence(timeout: 3.0) {
        let confirmButton = app.sheets.buttons[AccessibilityID.BookDetail.deleteButton]
        if confirmButton.exists {
          confirmButton.tap()
        }
      }
    }
    
    When("I wait for download to complete") { _, _ in
      let readButton = app.buttons[AccessibilityID.BookDetail.readButton]
      let listenButton = app.buttons[AccessibilityID.BookDetail.listenButton]
      
      let startTime = Date()
      while Date().timeIntervalSince(startTime) < 30.0 {
        if readButton.exists || listenButton.exists {
          return
        }
        TestHelpers.waitFor(0.5)
      }
      
      XCTFail("Download did not complete within 30 seconds")
    }
    
    When("I download the book") { _, _ in
      let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
      if TestHelpers.waitForElement(getButton, timeout: 5.0) {
        getButton.tap()
      }
      
      let startTime = Date()
      while Date().timeIntervalSince(startTime) < 30.0 {
        if app.buttons[AccessibilityID.BookDetail.readButton].exists ||
           app.buttons[AccessibilityID.BookDetail.listenButton].exists {
          return
        }
        TestHelpers.waitFor(0.5)
      }
    }
    
    Then("I should see the (GET|READ|LISTEN|DELETE|RESERVE) button") { args, _ in
      let buttonName = args![0] as! String
      let buttonID: String
      
      switch buttonName {
      case "GET": buttonID = AccessibilityID.BookDetail.getButton
      case "READ": buttonID = AccessibilityID.BookDetail.readButton
      case "LISTEN": buttonID = AccessibilityID.BookDetail.listenButton
      case "DELETE": buttonID = AccessibilityID.BookDetail.deleteButton
      case "RESERVE": buttonID = AccessibilityID.BookDetail.reserveButton
      default: XCTFail("Unknown button: \(buttonName)"); return
      }
      
      let button = app.buttons[buttonID]
      XCTAssertTrue(button.waitForExistence(timeout: 5.0), "\(buttonName) button should be visible")
    }
    
    Then("the book should download") { _, _ in
      let downloadComplete = app.buttons[AccessibilityID.BookDetail.readButton].waitForExistence(timeout: 30.0) ||
                            app.buttons[AccessibilityID.BookDetail.listenButton].waitForExistence(timeout: 30.0)
      XCTAssertTrue(downloadComplete, "Book should download successfully")
    }
    
    Then("the book should be in My Books") { _, _ in
      TestHelpers.navigateToTab("My Books")
      TestHelpers.waitFor(1.0)
      
      let bookCells = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'myBooks.bookCell.'"))
      XCTAssertGreaterThan(bookCells.count, 0, "Should have books in My Books")
    }
  }
}
