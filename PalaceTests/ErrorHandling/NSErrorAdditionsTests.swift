import XCTest
@testable import Palace

final class NSErrorAdditionsTests: XCTestCase {
  
  private let testDomain = "TestDomain"
  private let testCode = 100
  
  // MARK: - localizedDescriptionWithRecovery Tests
  
  func testLocalizedDescriptionWithRecovery_noRecoverySuggestion_returnsDescription() {
    let error = NSError(
      domain: testDomain,
      code: testCode,
      userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
    )
    
    XCTAssertEqual(error.localizedDescriptionWithRecovery, "Something went wrong")
  }
  
  func testLocalizedDescriptionWithRecovery_withRecoverySuggestion_returnsBoth() {
    let error = NSError(
      domain: testDomain,
      code: testCode,
      userInfo: [
        NSLocalizedDescriptionKey: "Download failed",
        NSLocalizedRecoverySuggestionErrorKey: "Please check your internet connection and try again."
      ]
    )
    
    let expected = "Download failed\n\nPlease check your internet connection and try again."
    XCTAssertEqual(error.localizedDescriptionWithRecovery, expected)
  }
  
  func testLocalizedDescriptionWithRecovery_emptyRecoverySuggestion_returnsDescriptionOnly() {
    let error = NSError(
      domain: testDomain,
      code: testCode,
      userInfo: [
        NSLocalizedDescriptionKey: "Something failed",
        NSLocalizedRecoverySuggestionErrorKey: ""
      ]
    )
    
    XCTAssertEqual(error.localizedDescriptionWithRecovery, "Something failed")
  }
  
  func testLocalizedDescriptionWithRecovery_whitespaceOnlyRecoverySuggestion_returnsDescriptionOnly() {
    let error = NSError(
      domain: testDomain,
      code: testCode,
      userInfo: [
        NSLocalizedDescriptionKey: "Error occurred",
        NSLocalizedRecoverySuggestionErrorKey: "   \n\t  "
      ]
    )
    
    XCTAssertEqual(error.localizedDescriptionWithRecovery, "Error occurred")
  }
  
  func testLocalizedDescriptionWithRecovery_nilDescription_usesDefaultDescription() {
    let error = NSError(
      domain: testDomain,
      code: testCode,
      userInfo: nil
    )
    
    // NSError provides a default localizedDescription when none is set
    XCTAssertFalse(error.localizedDescriptionWithRecovery.isEmpty)
  }
  
  func testLocalizedDescriptionWithRecovery_bothPresent_separatedByDoubleNewline() {
    let error = NSError(
      domain: testDomain,
      code: testCode,
      userInfo: [
        NSLocalizedDescriptionKey: "Part 1",
        NSLocalizedRecoverySuggestionErrorKey: "Part 2"
      ]
    )
    
    let result = error.localizedDescriptionWithRecovery
    XCTAssertTrue(result.contains("\n\n"))
    XCTAssertEqual(result.components(separatedBy: "\n\n").count, 2)
  }
  
  func testLocalizedDescriptionWithRecovery_multilineRecoverySuggestion() {
    let error = NSError(
      domain: testDomain,
      code: testCode,
      userInfo: [
        NSLocalizedDescriptionKey: "Authentication failed",
        NSLocalizedRecoverySuggestionErrorKey: "Step 1: Check username\nStep 2: Check password"
      ]
    )
    
    let expected = "Authentication failed\n\nStep 1: Check username\nStep 2: Check password"
    XCTAssertEqual(error.localizedDescriptionWithRecovery, expected)
  }
}

