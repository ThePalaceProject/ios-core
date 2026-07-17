//
//  OPDSFormatTests.swift
//  PalaceTests
//
//  Tests for OPDSFormat detection logic in UnifiedOPDSService.
//

import XCTest
import PalaceCatalog
@testable import Palace

/// SRS: NET-001 — GET/POST/PUT/DELETE execute with proper headers
@MainActor
class OPDSFormatTests: XCTestCase {

    // MARK: - Content-Type Detection

    func testDetectOPDS2FromJSONContentType() {
        let format = OPDSFormat.detect(from: "application/opds+json")
        XCTAssertEqual(format, .opds2)
        XCTAssertNotEqual(format, .opds1, "opds+json must not be mistaken for opds1")
        XCTAssertNotEqual(format, .unknown, "opds+json must not produce unknown")
    }

    func testDetectOPDS2FromGenericJSONContentType() {
        let format = OPDSFormat.detect(from: "application/json")
        XCTAssertEqual(format, .opds2)
        XCTAssertNotEqual(format, .opds1)
    }

    func testDetectOPDS1FromAtomXMLContentType() {
        let format = OPDSFormat.detect(from: "application/atom+xml")
        XCTAssertEqual(format, .opds1)
        XCTAssertNotEqual(format, .opds2, "atom+xml must not be mistaken for opds2")
        XCTAssertNotEqual(format, .unknown, "atom+xml must not produce unknown")
    }

    func testDetectOPDS1FromGenericXMLContentType() {
        let format = OPDSFormat.detect(from: "text/xml")
        XCTAssertEqual(format, .opds1)
        XCTAssertNotEqual(format, .opds2)
    }

    func testDetectUnknownFromNilContentType() {
        let format = OPDSFormat.detect(from: nil as String?)
        XCTAssertEqual(format, .unknown)
        XCTAssertNotEqual(format, .opds1, "nil content-type must not be opds1")
        XCTAssertNotEqual(format, .opds2, "nil content-type must not be opds2")
    }

    func testDetectUnknownFromUnrelatedContentType() {
        let format = OPDSFormat.detect(from: "text/plain")
        XCTAssertEqual(format, .unknown)
        XCTAssertNotEqual(format, .opds1)
        XCTAssertNotEqual(format, .opds2)
    }

    func testDetectIsCaseInsensitive() {
        let format = OPDSFormat.detect(from: "APPLICATION/OPDS+JSON")
        XCTAssertEqual(format, .opds2)
        // Mixed case should also work
        let mixedCase = OPDSFormat.detect(from: "Application/Atom+XML")
        XCTAssertEqual(mixedCase, .opds1, "Case-insensitive detection must work for atom+xml")
    }

    // MARK: - Data-Based Detection

    func testDetectOPDS2FromJSONData() {
        let data = Data("{\"title\": \"Test\"}".utf8)
        let format = OPDSFormat.detect(from: data)
        XCTAssertEqual(format, .opds2)
        XCTAssertNotEqual(format, .opds1, "JSON data must not be detected as opds1")
    }

    func testDetectOPDS2FromJSONArrayData() {
        let data = Data("[{\"title\": \"Test\"}]".utf8)
        let format = OPDSFormat.detect(from: data)
        XCTAssertEqual(format, .opds2)
        XCTAssertNotEqual(format, .unknown, "JSON array data must not produce unknown")
    }

    func testDetectOPDS1FromXMLData() {
        let data = Data("<?xml version=\"1.0\"?>".utf8)
        let format = OPDSFormat.detect(from: data)
        XCTAssertEqual(format, .opds1)
        XCTAssertNotEqual(format, .opds2, "XML data must not be detected as opds2")
    }

    func testDetectUnknownFromEmptyData() {
        let format = OPDSFormat.detect(from: Data())
        XCTAssertEqual(format, .unknown)
        XCTAssertNotEqual(format, .opds1, "Empty data must not produce opds1")
        XCTAssertNotEqual(format, .opds2, "Empty data must not produce opds2")
    }

    // MARK: - OPDSFormat rawValue

    func testOPDS2RawValue() {
        // Round-trip: detecting from rawValue must yield the same format (behavior, not definition)
        XCTAssertEqual(OPDSFormat.detect(from: OPDSFormat.opds2.rawValue), .opds2,
                       "Detecting opds2 rawValue must produce opds2 (round-trip)")
        // The rawValue must not be mistaken for opds1 or unknown
        XCTAssertNotEqual(OPDSFormat.detect(from: OPDSFormat.opds2.rawValue), .opds1,
                          "opds2 rawValue must not detect as opds1")
        XCTAssertNotEqual(OPDSFormat.detect(from: OPDSFormat.opds2.rawValue), .unknown,
                          "opds2 rawValue must not detect as unknown")
    }

    func testOPDS1RawValue() {
        // Round-trip: detecting from rawValue must yield the same format (behavior, not definition)
        XCTAssertEqual(OPDSFormat.detect(from: OPDSFormat.opds1.rawValue), .opds1,
                       "Detecting opds1 rawValue must produce opds1 (round-trip)")
        // The rawValue must not be mistaken for opds2 or unknown
        XCTAssertNotEqual(OPDSFormat.detect(from: OPDSFormat.opds1.rawValue), .opds2,
                          "opds1 rawValue must not detect as opds2")
        XCTAssertNotEqual(OPDSFormat.detect(from: OPDSFormat.opds1.rawValue), .unknown,
                          "opds1 rawValue must not detect as unknown")
    }
}
