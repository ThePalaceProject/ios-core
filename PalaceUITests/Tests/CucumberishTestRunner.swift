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
    
    print("🔧 Cucumberish: Registering step definitions...")
    
    // Set up basic Palace step definitions (Batch 1 - 65 steps)
    PalaceNavigationSteps.setup()
    PalaceSearchSteps.setup()
    PalaceBookActionSteps.setup()
    PalaceAudiobookSteps.setup()
    PalaceAssertionSteps.setup()
    
    // Set up migrated step definitions (Batch 2 - 115 steps)
    TutorialAndLibrarySteps.setup()
    ComplexSearchSteps.setup()
    ComplexBookActionSteps.setup()
    AuthenticationSteps.setup()
    CatalogAndVerificationSteps.setup()
    EpubAndPdfReaderSteps.setup()
    AdvancedAudiobookSteps.setup()
    
    print("✅ Cucumberish: Registered 180 step definitions")
    
    // Standard Cucumberish initialization
    // Use default bundle search - Cucumberish auto-discovers .feature files
    let bundle = Bundle(for: CucumberishTestRunner.self)
    
    // Cucumberish.executeFeaturesInDirectory searches bundle for .feature files
    // Pass empty string to search bundle root
    Cucumberish.executeFeaturesInDirectory(
      "",  
      from: bundle,
      includeTags: nil,
      excludeTags: ["@wip", "@skip", "@exclude_android"]
    )
  }
}

/// XCTest integration point - this makes Cucumberish visible in Xcode Test Navigator
final class CucumberishInitializer: XCTestCase {
  
  override class func setUp() {
    super.setUp()
    print("🚀 Cucumberish: Starting test execution...")
    CucumberishTestRunner.setup()
  }
  
  // This test method triggers Cucumberish execution
  func testCucumberish() {
    // Cucumberish runs via setUp()
    // Scenarios execute from .feature files
    print("✅ Cucumberish: Test execution complete")
  }
}
