//
//  EPUBPositionTests.swift
//  PalaceTests
//
//  Tests for TPPBookLocation creation, serialization, and throttling.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import ReadiumShared
@testable import Palace
import PalaceBookModel

// Deliberately NOT @MainActor: TPPBookLocation/Publication are non-Sendable
// and convertToLocator is nonisolated async — a @MainActor test makes those
// Swift 6 sending errors. Pure model round-trip tests, no UI.
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

    // MARK: - Locator round-trip (PP-4340 JSONValue migration)

    /// Covers the serialization path changed by the Readium 3.9.0 JSONValue
    /// migration: `init?(locator:)` reads `otherLocations[cssSelector]?.string`
    /// and serializes via the new Foundation `jsonString(from:)` helper, and
    /// `convertToLocator` rebuilds `otherLocations` as `[String: JSONValue]`.
    /// A regression on any changed line — dropping `.string`, failing to wrap
    /// the value in `JSONValue`, or a broken serializer — breaks this
    /// round-trip while leaving the pre-existing string/dictionary tests green.
    // `nonisolated`: `convertToLocator(publication:)` is a nonisolated `async`
    // method that takes non-Sendable Readium values (`Publication`, and the
    // `TPPBookLocation` receiver). Awaiting it from the class's `@MainActor`
    // isolation would *send* those non-Sendable args across the actor hop
    // (Swift 6 "sending risks data races"). Running the test method itself in
    // the nonisolated domain — the same domain as the callee, matching the
    // production caller `TPPLastReadPositionSynchronizer.syncReadPosition` —
    // removes the boundary entirely, so nothing is sent. The body touches no
    // MainActor state (only nonisolated factories, initializers, and XCTAssert).
    nonisolated func testLocatorRoundTrip_preservesCssSelectorPositionProgression_throughJSONValue() async {
        let publication = Self.makeTestPublication()
        guard let href = AnyURL(string: "/chapter1.xhtml") else {
            return XCTFail("invalid test href")
        }
        let original = Locator(
            href: href,
            mediaType: .xhtml,
            title: "Chapter One",
            locations: Locator.Locations(
                progression: 0.5,
                totalProgression: 0.25,
                position: 7,
                otherLocations: ["cssSelector": .string("#para-3")]
            )
        )

        guard let bookLocation = TPPBookLocation(locator: original,
                                                 type: "LocatorHrefProgression",
                                                 publication: publication) else {
            return XCTFail("TPPBookLocation(locator:) returned nil")
        }
        // The `?.string` read + `jsonString(from:)` serializer must have emitted the selector.
        XCTAssertTrue(bookLocation.locationString.contains("#para-3"),
                      "cssSelector must appear in the serialized locationString")

        let restored = await bookLocation.convertToLocator(publication: publication)
        XCTAssertEqual(restored?.locations.otherLocations["cssSelector"]?.string, "#para-3",
                       "cssSelector must survive the JSONValue bridge in convertToLocator")
        XCTAssertEqual(restored?.locations.position, 7)
        XCTAssertEqual(restored?.locations.progression, 0.5)
        XCTAssertEqual(restored?.title, "Chapter One")
    }

    /// Edge: no cssSelector exercises the `?? ""` / `?? [:]` branches — the
    /// round-trip must still succeed and must not fabricate a non-empty selector.
    // `nonisolated`: see the note on the sibling round-trip test above — the
    // nonisolated `await convertToLocator` hop would otherwise send the
    // non-Sendable `bookLocation`/`publication` across the `@MainActor` boundary.
    nonisolated func testLocatorRoundTrip_withoutCssSelector_succeedsAndPreservesPosition() async {
        let publication = Self.makeTestPublication()
        guard let href = AnyURL(string: "/chapter1.xhtml") else {
            return XCTFail("invalid test href")
        }
        let original = Locator(
            href: href,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.1, totalProgression: 0.1, position: 2)
        )
        guard let bookLocation = TPPBookLocation(locator: original,
                                                 type: "LocatorHrefProgression",
                                                 publication: publication) else {
            return XCTFail("TPPBookLocation(locator:) returned nil")
        }
        let restored = await bookLocation.convertToLocator(publication: publication)
        XCTAssertNotNil(restored, "round-trip must succeed without a cssSelector")
        XCTAssertEqual(restored?.locations.position, 2)
        XCTAssertEqual(restored?.locations.otherLocations["cssSelector"]?.string ?? "", "",
                       "no real selector should be fabricated when none was provided")
    }

    // `nonisolated`: pure factory with no MainActor state, so the two
    // `nonisolated` round-trip tests can build a publication without a cross-actor hop.
    private nonisolated static func makeTestPublication() -> Publication {
        let metadata = Metadata(title: "Test", languages: ["en"])
        let readingOrder = [Link(href: "/chapter1.xhtml", mediaType: .xhtml)]
        return Publication(manifest: Manifest(metadata: metadata, readingOrder: readingOrder))
    }
}
