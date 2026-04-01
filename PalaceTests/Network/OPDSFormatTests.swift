//
//  OPDSFormatTests.swift
//  PalaceTests
//
//  Tests for OPDSFormat detection logic in UnifiedOPDSService.
//

import XCTest
@testable import Palace

/// SRS: NET-001 — GET/POST/PUT/DELETE execute with proper headers
class OPDSFormatTests: XCTestCase {

    // MARK: - Content-Type Detection

    func testDetectOPDS2FromJSONContentType() {
        let format = OPDSFormat.detect(from: "application/opds+json")
        XCTAssertEqual(format, .opds2)
    }

    func testDetectOPDS2FromGenericJSONContentType() {
        let format = OPDSFormat.detect(from: "application/json")
        XCTAssertEqual(format, .opds2)
    }

    func testDetectOPDS1FromAtomXMLContentType() {
        let format = OPDSFormat.detect(from: "application/atom+xml")
        XCTAssertEqual(format, .opds1)
    }

    func testDetectOPDS1FromGenericXMLContentType() {
        let format = OPDSFormat.detect(from: "text/xml")
        XCTAssertEqual(format, .opds1)
    }

    func testDetectUnknownFromNilContentType() {
        let format = OPDSFormat.detect(from: nil as String?)
        XCTAssertEqual(format, .unknown)
    }

    func testDetectUnknownFromUnrelatedContentType() {
        let format = OPDSFormat.detect(from: "text/plain")
        XCTAssertEqual(format, .unknown)
    }

    func testDetectIsCaseInsensitive() {
        let format = OPDSFormat.detect(from: "APPLICATION/OPDS+JSON")
        XCTAssertEqual(format, .opds2)
    }

    // MARK: - Data-Based Detection

    func testDetectOPDS2FromJSONData() {
        let data = Data("{\"title\": \"Test\"}".utf8)
        let format = OPDSFormat.detect(from: data)
        XCTAssertEqual(format, .opds2)
    }

    func testDetectOPDS2FromJSONArrayData() {
        let data = Data("[{\"title\": \"Test\"}]".utf8)
        let format = OPDSFormat.detect(from: data)
        XCTAssertEqual(format, .opds2)
    }

    func testDetectOPDS1FromXMLData() {
        let data = Data("<?xml version=\"1.0\"?>".utf8)
        let format = OPDSFormat.detect(from: data)
        XCTAssertEqual(format, .opds1)
    }

    func testDetectUnknownFromEmptyData() {
        let format = OPDSFormat.detect(from: Data())
        XCTAssertEqual(format, .unknown)
    }

    // MARK: - OPDSFormat rawValue

    func testOPDS2RawValue() {
        XCTAssertEqual(OPDSFormat.opds2.rawValue, "application/opds+json")
    }

    func testOPDS1RawValue() {
        XCTAssertEqual(OPDSFormat.opds1.rawValue, "application/atom+xml")
    }
}
