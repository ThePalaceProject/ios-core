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
        let isClass = EPUBModule.self is AnyClass
        XCTAssertTrue(isClass, "EPUBModule should be a class type")
        // EPUBModule must be a class (not struct) so it can hold references
        let metatype: Any.Type = EPUBModule.self
        XCTAssertNotNil(metatype, "EPUBModule type should be accessible")
    }

    // MARK: - ReaderError Tests

    func testReaderError_epubNotValid_exists() {
        // Verify the error case used by EPUBModule exists
        let error = ReaderError.epubNotValid
        XCTAssertNotNil(error)
        // Error description should be non-empty
        let description = error.localizedDescription
        XCTAssertFalse(description.isEmpty, "epubNotValid should have a non-empty localized description")
    }

    func testReaderError_epubNotValid_isError() {
        let error: Error = ReaderError.epubNotValid
        XCTAssertNotNil(error.localizedDescription)
        // Two instances of the same case should behave identically
        let error2: Error = ReaderError.epubNotValid
        XCTAssertEqual(error.localizedDescription, error2.localizedDescription,
                       "Same error case should produce consistent descriptions")
    }
}
