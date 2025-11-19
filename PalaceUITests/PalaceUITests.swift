//
//  PalaceUITests.swift
//  PalaceUITests
//
//  Cucumberish Test Runner
//

import XCTest
import Cucumberish

/// Main test runner for Cucumberish tests
///
/// **How it works:**
/// 1. Cucumberish loads all .feature files from Features/ directory
/// 2. Matches Gherkin steps to Swift step definitions
/// 3. Runs as XCTest suite
///
/// **For QA:**
/// - Write .feature files in Features/ directory
/// - Use predefined steps from STEP_LIBRARY.md
/// - Run tests with ⌘U in Xcode
class CucumberishTestRunner: NSObject {
  
  @objc class func setup() {
    // Configure test environment
    let app = XCUIApplication()
    app.launchArguments = ["-testMode", "1"]
    app.launchEnvironment = ["DISABLE_ANIMATIONS": "1"]
    
    // Set up all Palace step definitions
    PalaceNavigationSteps.setup()
    PalaceSearchSteps.setup()
    PalaceBookActionSteps.setup()
    PalaceAudiobookSteps.setup()
    PalaceAssertionSteps.setup()
    
    // Configure Cucumberish to find .feature files
    let bundle = Bundle(for: CucumberishTestRunner.self)
    Cucumberish.executeFeatures(
      inDirectory: "Features",
      from: bundle,
      includeTags: nil,
      excludeTags: ["@wip", "@skip"]
    )
  }
}

/// XCTest integration point - this makes Cucumberish visible in Xcode Test Navigator
final class CucumberishInitializer: XCTestCase {
  
  override class func setUp() {
    super.setUp()
    CucumberishTestRunner.setup()
  }
  
  // Cucumberish will dynamically create test methods from .feature files
  // They will appear in the Test Navigator when you run tests
}
