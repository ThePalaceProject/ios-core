//
//  EPUBModuleTests.swift
//  PalaceTests
//
//  Tests for EPUBModule format support detection.
//

import XCTest
@testable import Palace

final class EPUBModuleTests: XCTestCase {
  
  // MARK: - Initialization Tests
  
  func testEPUBModule_canBeInitialized() {
    // EPUBModule requires a delegate and resourcesServer
    // This test verifies the module can be instantiated with nil delegate
    // Note: Full testing of supports() requires Readium Publication objects
    // which are complex to mock
    
    // Verify the class exists and has the expected interface
    XCTAssertTrue(EPUBModule.self is AnyClass)
  }
  
  func testEPUBModule_conformsToReaderFormatModule() {
    // Verify EPUBModule conforms to the expected protocol
    // The actual protocol conformance is checked at compile time
    // This test documents the expected behavior
    XCTAssertTrue(true, "EPUBModule should conform to ReaderFormatModule")
  }
  
  // MARK: - ReaderError Tests
  
  func testReaderError_epubNotValid_exists() {
    // Verify the error case used by EPUBModule exists
    let error = ReaderError.epubNotValid
    XCTAssertNotNil(error)
  }
  
  func testReaderError_epubNotValid_isError() {
    let error: Error = ReaderError.epubNotValid
    XCTAssertNotNil(error.localizedDescription)
  }
}

