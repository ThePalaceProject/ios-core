//
//  TPPBookLocationTests.swift
//  PalaceTests
//
//  Tests for TPPBookLocation: init, dictionary round-trip, locationStringDictionary,
//  isSimilarTo comparison logic, and TPPBookLocationData extension.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookLocationEdgeCaseTests: XCTestCase {

    // MARK: - Init from string/renderer

    func test_init_withValidStringAndRenderer_createsLocation() {
        let location = TPPBookLocation(locationString: "chapter3", renderer: "readium")
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "chapter3")
        XCTAssertEqual(location?.renderer, "readium")
    }

    func test_init_withEmptyLocationString_createsLocation() {
        let location = TPPBookLocation(locationString: "", renderer: "readium")
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "")
    }

    func test_init_withEmptyRenderer_createsLocation() {
        let location = TPPBookLocation(locationString: "chapter1", renderer: "")
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.renderer, "")
    }

    func test_init_withLongJSON_createsLocation() {
        let jsonString = """
        {"href":"/chapter/1","progression":0.42,"totalProgression":0.15}
        """
        let location = TPPBookLocation(locationString: jsonString, renderer: "readium-2")
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, jsonString)
    }

    // MARK: - Init from dictionary

    func test_initFromDictionary_withValidData_createsLocation() {
        let dict: [String: Any] = [
            "locationString": "page42",
            "renderer": "rmsdk"
        ]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "page42")
        XCTAssertEqual(location?.renderer, "rmsdk")
    }

    func test_initFromDictionary_missingLocationString_returnsNil() {
        let dict: [String: Any] = ["renderer": "readium"]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNil(location)
    }

    func test_initFromDictionary_missingRenderer_returnsNil() {
        let dict: [String: Any] = ["locationString": "chapter1"]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNil(location)
    }

    func test_initFromDictionary_emptyDictionary_returnsNil() {
        let location = TPPBookLocation(dictionary: [:])
        XCTAssertNil(location)
    }

    func test_initFromDictionary_wrongTypes_returnsNil() {
        let dict: [String: Any] = [
            "locationString": 42,
            "renderer": true
        ]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNil(location)
    }

    func test_initFromDictionary_extraKeys_ignoresExtras() {
        let dict: [String: Any] = [
            "locationString": "chapter5",
            "renderer": "readium",
            "extraKey": "extraValue"
        ]
        let location = TPPBookLocation(dictionary: dict)
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.locationString, "chapter5")
    }

    // MARK: - Dictionary round-trip

    func test_dictionaryRepresentation_roundTrips() {
        let original = TPPBookLocation(locationString: "loc-123", renderer: "readium-2")!
        let dict = original.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dict)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.locationString, original.locationString)
        XCTAssertEqual(restored?.renderer, original.renderer)
    }

    func test_dictionaryRepresentation_containsExpectedKeys() {
        let location = TPPBookLocation(locationString: "test", renderer: "r")!
        let dict = location.dictionaryRepresentation

        XCTAssertEqual(dict["locationString"] as? String, "test")
        XCTAssertEqual(dict["renderer"] as? String, "r")
        XCTAssertEqual(dict.count, 2)
    }

    func test_dictionaryRepresentation_preservesJSONContent() {
        let json = """
        {"chapter":"3","position":0.75}
        """
        let location = TPPBookLocation(locationString: json, renderer: "readium")!
        let dict = location.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dict)

        XCTAssertEqual(restored?.locationString, json)
    }

    // MARK: - TPPBookLocationData extension

    func test_bookLocationData_stringForKey_returnsValue() {
        let data: TPPBookLocationData = [
            "locationString": "chapter1",
            "renderer": "readium"
        ]
        XCTAssertEqual(data.string(for: .locationString), "chapter1")
        XCTAssertEqual(data.string(for: .renderer), "readium")
    }

    func test_bookLocationData_stringForKey_missingKey_returnsNil() {
        let data: TPPBookLocationData = [:]
        XCTAssertNil(data.string(for: .locationString))
        XCTAssertNil(data.string(for: .renderer))
    }

    func test_bookLocationData_stringForKey_wrongType_returnsNil() {
        let data: TPPBookLocationData = [
            "locationString": 42
        ]
        XCTAssertNil(data.string(for: .locationString))
    }

    // MARK: - locationStringDictionary

    func test_locationStringDictionary_validJSON_returnsParsedDictionary() {
        let json = """
        {"href":"/chapter/1","progression":0.42}
        """
        let location = TPPBookLocation(locationString: json, renderer: "readium")!
        let dict = location.locationStringDictionary()

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["href"] as? String, "/chapter/1")
        XCTAssertEqual(dict?["progression"] as? Double ?? -1, 0.42, accuracy: 0.001)
    }

    func test_locationStringDictionary_invalidJSON_returnsNil() {
        let location = TPPBookLocation(locationString: "not json at all", renderer: "readium")!
        let dict = location.locationStringDictionary()

        XCTAssertNil(dict)
    }

    func test_locationStringDictionary_emptyString_returnsNil() {
        let location = TPPBookLocation(locationString: "", renderer: "readium")!
        let dict = location.locationStringDictionary()

        XCTAssertNil(dict)
    }

    func test_locationStringDictionary_arrayJSON_returnsNil() {
        // JSON array is not a dictionary
        let location = TPPBookLocation(locationString: "[1,2,3]", renderer: "readium")!
        let dict = location.locationStringDictionary()

        XCTAssertNil(dict)
    }

    // MARK: - isSimilarTo

    func test_isSimilarTo_identicalLocations_returnsTrue() {
        let json = """
        {"href":"/chapter/1","progression":0.42}
        """
        let a = TPPBookLocation(locationString: json, renderer: "readium")!
        let b = TPPBookLocation(locationString: json, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }

    func test_isSimilarTo_differentRenderer_returnsFalse() {
        let json = """
        {"href":"/chapter/1","progression":0.42}
        """
        let a = TPPBookLocation(locationString: json, renderer: "readium")!
        let b = TPPBookLocation(locationString: json, renderer: "rmsdk")!

        XCTAssertFalse(a.isSimilarTo(b))
    }

    func test_isSimilarTo_differentContent_returnsFalse() {
        let jsonA = """
        {"href":"/chapter/1","progression":0.42}
        """
        let jsonB = """
        {"href":"/chapter/2","progression":0.50}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertFalse(a.isSimilarTo(b))
    }

    func test_isSimilarTo_ignoresTimeStampDifferences() {
        let jsonA = """
        {"href":"/chapter/1","progression":0.42,"timeStamp":"2024-01-01T00:00:00Z"}
        """
        let jsonB = """
        {"href":"/chapter/1","progression":0.42,"timeStamp":"2024-06-15T12:00:00Z"}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }

    func test_isSimilarTo_ignoresAnnotationIdDifferences() {
        let jsonA = """
        {"href":"/chapter/1","progression":0.42,"annotationId":"aaa-111"}
        """
        let jsonB = """
        {"href":"/chapter/1","progression":0.42,"annotationId":"bbb-222"}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }

    func test_isSimilarTo_nonJSONLocationString_returnsFalse() {
        // When locationString is not valid JSON, locationStringDictionary returns nil
        // so isSimilarTo should return false
        let a = TPPBookLocation(locationString: "plaintext", renderer: "readium")!
        let b = TPPBookLocation(locationString: "plaintext", renderer: "readium")!

        XCTAssertFalse(a.isSimilarTo(b))
    }

    func test_isSimilarTo_sameContentDifferentTimeStampAndAnnotationId_returnsTrue() {
        let jsonA = """
        {"href":"/ch/5","progression":0.9,"timeStamp":"2024-01-01","annotationId":"id1","page":42}
        """
        let jsonB = """
        {"href":"/ch/5","progression":0.9,"timeStamp":"2024-12-31","annotationId":"id2","page":42}
        """
        let a = TPPBookLocation(locationString: jsonA, renderer: "readium")!
        let b = TPPBookLocation(locationString: jsonB, renderer: "readium")!

        XCTAssertTrue(a.isSimilarTo(b))
    }
}
