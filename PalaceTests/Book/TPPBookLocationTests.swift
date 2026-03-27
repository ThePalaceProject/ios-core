//
//  TPPBookLocationTests.swift
//  PalaceTests
//
//  Tests for TPPBookLocation initialization, dictionary representation,
//  and TPPBookLocationData extension.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookLocationExtendedTests: XCTestCase {

    // MARK: - Init with strings

    func testInit_ValidStrings_CreatesLocation() {
        let location = TPPBookLocation(locationString: "chapter1", renderer: "readium")

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "chapter1")
        XCTAssertEqual(location?.renderer, "readium")
    }

    func testInit_EmptyStrings_CreatesLocation() {
        // Empty strings are still valid — they are non-nil
        let location = TPPBookLocation(locationString: "", renderer: "")

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "")
        XCTAssertEqual(location?.renderer, "")
    }

    // MARK: - Init with dictionary

    func testInitDictionary_ValidKeys_CreatesLocation() {
        let dict: [String: Any] = [
            "locationString": "/chapter/2",
            "renderer": "readium"
        ]
        let location = TPPBookLocation(dictionary: dict)

        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "/chapter/2")
        XCTAssertEqual(location?.renderer, "readium")
    }

    func testInitDictionary_MissingLocationString_ReturnsNil() {
        let dict: [String: Any] = ["renderer": "readium"]
        let location = TPPBookLocation(dictionary: dict)

        XCTAssertNil(location)
    }

    func testInitDictionary_MissingRenderer_ReturnsNil() {
        let dict: [String: Any] = ["locationString": "chapter1"]
        let location = TPPBookLocation(dictionary: dict)

        XCTAssertNil(location)
    }

    func testInitDictionary_EmptyDictionary_ReturnsNil() {
        let location = TPPBookLocation(dictionary: [:])

        XCTAssertNil(location)
    }

    func testInitDictionary_WrongValueTypes_ReturnsNil() {
        let dict: [String: Any] = [
            "locationString": 123,
            "renderer": true
        ]
        let location = TPPBookLocation(dictionary: dict)

        XCTAssertNil(location)
    }

    // MARK: - Dictionary Representation

    func testDictionaryRepresentation_ContainsCorrectKeys() {
        let location = TPPBookLocation(locationString: "loc", renderer: "rend")!
        let dict = location.dictionaryRepresentation

        XCTAssertEqual(dict["locationString"] as? String, "loc")
        XCTAssertEqual(dict["renderer"] as? String, "rend")
        XCTAssertEqual(dict.count, 2)
    }

    func testDictionaryRepresentation_RoundTrips() {
        let original = TPPBookLocation(locationString: "page/5", renderer: "pdf")!
        let dict = original.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dict)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.locationString, original.locationString)
        XCTAssertEqual(restored?.renderer, original.renderer)
    }

    // MARK: - TPPBookLocationData Extension

    func testBookLocationData_StringForKey_ReturnsValue() {
        let data: TPPBookLocationData = [
            "locationString": "test-location",
            "renderer": "test-renderer"
        ]

        XCTAssertEqual(data.string(for: .locationString), "test-location")
        XCTAssertEqual(data.string(for: .renderer), "test-renderer")
    }

    func testBookLocationData_StringForKey_MissingKey_ReturnsNil() {
        let data: TPPBookLocationData = [:]

        XCTAssertNil(data.string(for: .locationString))
        XCTAssertNil(data.string(for: .renderer))
    }

    func testBookLocationData_StringForKey_NonStringValue_ReturnsNil() {
        let data: TPPBookLocationData = ["locationString": 42]

        XCTAssertNil(data.string(for: .locationString))
    }

    // MARK: - TPPBookLocationKey enum

    func testBookLocationKey_RawValues() {
        XCTAssertEqual(TPPBookLocationKey.locationString.rawValue, "locationString")
        XCTAssertEqual(TPPBookLocationKey.renderer.rawValue, "renderer")
    }
}
