//
//  EPUBPositionTests.swift
//  PalaceTests
//
//  Tests for TPPBookLocation creation, serialization, and throttling.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class EPUBPositionTests: XCTestCase {

    // MARK: - TPPBookLocation Creation Tests

    func testBookLocation_CreationWithValidData() {
        let locationString = """
    {"@type":"LocatorHrefProgression","href":"/OEBPS/chapter01.xhtml","locations":{"progression":0.5}}
    """

        let location = TPPBookLocation(locationString: locationString, renderer: TPPBookLocation.r3Renderer)

        XCTAssertEqual(location?.locationString, locationString)
        XCTAssertEqual(location?.renderer, TPPBookLocation.r3Renderer)
        XCTAssertEqual(location?.locationString.count, locationString.count,
                       "locationString must be stored verbatim without truncation")
    }

    func testBookLocation_DictionaryRoundTrip() {
        let originalLocationString = """
    {"@type":"LocatorHrefProgression","href":"/chapter.xhtml","locations":{"progression":0.25}}
    """

        let original = TPPBookLocation(locationString: originalLocationString, renderer: TPPBookLocation.r3Renderer)

        let dictionary = original!.dictionaryRepresentation
        let restored = TPPBookLocation(dictionary: dictionary)

        XCTAssertEqual(restored?.locationString, originalLocationString)
        XCTAssertEqual(restored?.renderer, TPPBookLocation.r3Renderer)
        XCTAssertEqual(restored?.locationString, original?.locationString,
                       "Round-tripped locationString must match the original exactly")
    }

    func testBookLocation_CreationFromDictionary() {
        let dictionary: [String: Any] = [
            "locationString": "{\"href\":\"/chapter.xhtml\"}",
            "renderer": TPPBookLocation.r3Renderer
        ]

        let location = TPPBookLocation(dictionary: dictionary)

        XCTAssertEqual(location?.renderer, TPPBookLocation.r3Renderer)
        XCTAssertEqual(location?.locationString, "{\"href\":\"/chapter.xhtml\"}",
                       "locationString must match the value stored in the dictionary")
    }

    func testBookLocation_FailsWithMissingLocationString() {
        let dictionary: [String: Any] = [
            "renderer": TPPBookLocation.r3Renderer
        ]

        let location = TPPBookLocation(dictionary: dictionary)

        XCTAssertNil(location, "Should fail with missing locationString")
    }

    func testBookLocation_FailsWithMissingRenderer() {
        let dictionary: [String: Any] = [
            "locationString": "{\"href\":\"/chapter.xhtml\"}"
        ]

        let location = TPPBookLocation(dictionary: dictionary)

        XCTAssertNil(location, "Should fail with missing renderer")
    }

    // MARK: - Location Comparison Tests

    func testLocationSimilarity_IdenticalLocations() {
        let location1 = TPPBookLocation(
            locationString: "{\"href\":\"/chapter.xhtml\",\"progression\":0.5}",
            renderer: TPPBookLocation.r3Renderer
        )!

        let location2 = TPPBookLocation(
            locationString: "{\"href\":\"/chapter.xhtml\",\"progression\":0.5}",
            renderer: TPPBookLocation.r3Renderer
        )!

        XCTAssertEqual(location1.locationString, location2.locationString)
    }

    func testLocationSimilarity_DifferentProgressions() {
        let location1 = TPPBookLocation(
            locationString: "{\"progression\":0.25}",
            renderer: TPPBookLocation.r3Renderer
        )!

        let location2 = TPPBookLocation(
            locationString: "{\"progression\":0.75}",
            renderer: TPPBookLocation.r3Renderer
        )!

        XCTAssertNotEqual(location1.locationString, location2.locationString)
    }

    // MARK: - Throttling Constant Tests

    func testThrottlingInterval_Value() {
        let expectedInterval: TimeInterval = 15.0

        XCTAssertEqual(TPPLastReadPositionPoster.throttlingInterval, expectedInterval)
        XCTAssertGreaterThan(TPPLastReadPositionPoster.throttlingInterval, 0,
                             "Throttling interval must be positive to prevent infinite sync loops")
        XCTAssertLessThan(TPPLastReadPositionPoster.throttlingInterval, 60,
                          "Throttling interval must be less than 60s to ensure position is saved frequently enough")
    }
}
