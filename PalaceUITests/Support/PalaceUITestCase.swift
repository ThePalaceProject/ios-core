import XCTest

class PalaceUITestCase: XCTestCase {
  var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += ["--uitesting"]
    // Add environment vars from TestCredentials if available
    if let credentials = TestCredentials.load() {
      app.launchEnvironment["TEST_BARCODE"] = credentials.barcode
      app.launchEnvironment["TEST_PIN"] = credentials.pin
      app.launchEnvironment["TEST_LIBRARY"] = credentials.library
    }
    app.launch()
  }

  override func tearDownWithError() throws {
    app = nil
  }
}
