//
//  EPUBPositionWireFormatTests.swift
//  PalaceTests
//
//  PP-5138: pins the bytes Palace puts on the annotation server for an EPUB
//  reading position, and the bytes it accepts back.
//
//  The wire format is `LocatorHrefProgression` from
//  `ThePalaceProject/mobile-specs`:
//
//      {"@type":"LocatorHrefProgression","href":…,"progressWithinChapter":…}
//
//  Palace used to post the Readium `Locator` shape instead — no `@type`, no
//  `progressWithinChapter`, progressions nested under `locations`. The spec
//  directs a client meeting an untyped locator to read it as
//  `LocatorLegacyCFI`, and the Android client does that and then discards the
//  result for EPUBs, so no position written by iOS was ever readable there.
//
//  The read side still accepts the Readium shape, because positions in that
//  shape are already on the server from shipped versions.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import ReadiumShared
@testable import Palace
import PalaceBookModel

// Deliberately NOT @MainActor — `Publication` / `TPPBookLocation` are
// non-Sendable and `convertToLocator` is `nonisolated async`.
final class EPUBPositionWireFormatTests: XCTestCase {

    // MARK: - Helpers mirroring production

    /// What the local book registry stores, and — since PP-5138 — the exact
    /// bytes `TPPLastReadPositionPoster` posts. Mirrors `storeReadPosition`.
    private func locationString(for locator: Locator,
                                publication: Publication) throws -> String {
        let location = try XCTUnwrap(
            TPPBookLocation(locator: locator,
                            type: "LocatorHrefProgression",
                            publication: publication),
            "TPPBookLocation(locator:) must not return nil for a mid-chapter locator"
        )
        return location.locationString
    }

    private func parse(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "position payload must be a JSON object"
        )
    }

    // MARK: - Spec conformance of what we write

    /// The three keys the spec's schema lists as `required` for a
    /// `LocatorHrefProgression`. Without `@type` the spec tells the reader to
    /// treat the payload as a legacy CFI locator, which is how an iOS position
    /// became invisible on Android.
    func testWrittenPosition_CarriesTheSpecRequiredKeys() throws {
        let publication = Self.makeTestPublication()
        let json = try parse(locationString(for: Self.midChapterLocator(),
                                            publication: publication))

        XCTAssertEqual(json["@type"] as? String, "LocatorHrefProgression",
                       "a locator with no @type is read as LocatorLegacyCFI and dropped by the Android EPUB reader")
        XCTAssertEqual(json["href"] as? String, "/chapter1.xhtml")
        XCTAssertEqual(json["progressWithinChapter"] as? Double, 0.62,
                       "progressWithinChapter is required, and is the only chapter offset the spec defines")
    }

    /// The Readium shape nests progression under `locations` and names the
    /// chapter offset `progression`. Neither key may appear at the top level of
    /// what we write, or we are back to the shape Android cannot read.
    func testWrittenPosition_IsNotTheReadiumLocatorShape() throws {
        let publication = Self.makeTestPublication()
        let json = try parse(locationString(for: Self.midChapterLocator(),
                                            publication: publication))

        XCTAssertNil(json["locations"], "the spec locator is flat; `locations` is the Readium shape")
        XCTAssertNil(json["progression"], "the spec's chapter offset key is progressWithinChapter")
    }

    /// Android's locator constructor range-checks the chapter progression and
    /// THROWS outside 0.0…1.0. That throw escapes its per-annotation catch and
    /// empties the patron's whole bookmark list. Never emit one.
    func testWrittenPosition_ClampsProgressionToUnitInterval() throws {
        let publication = Self.makeTestPublication()

        let overshoot = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 1.4, totalProgression: 2.0)
        )
        let high = try parse(locationString(for: overshoot, publication: publication))
        XCTAssertEqual(high["progressWithinChapter"] as? Double, 1.0)
        XCTAssertEqual(high["progressWithinBook"] as? Double, 1.0)

        let undershoot = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: -0.5, totalProgression: -0.1)
        )
        let low = try parse(locationString(for: undershoot, publication: publication))
        XCTAssertEqual(low["progressWithinChapter"] as? Double, 0.0)
        XCTAssertEqual(low["progressWithinBook"] as? Double, 0.0)
    }

    // MARK: - Conformance against the vendored spec fixtures
    //
    // The spec repo ships a corpus of valid/invalid locators. Android runs it
    // as a conformance suite; nothing in this project loaded it, which is why
    // the wire format could drift away from the spec without anything failing.

    /// Every `LocatorHrefProgression` the spec calls valid must parse, and the
    /// two required fields must come back intact.
    func testSpecFixtures_ValidHrefProgressionLocatorsParse() throws {
        let fixture = """
        {"@type":"LocatorHrefProgression","href":"/xyz.html","progressWithinChapter":0.666}
        """
        let fields = try XCTUnwrap(EPUBPositionDialect(jsonString: fixture),
                                   "valid-locator-0.json from the spec corpus must parse")

        XCTAssertEqual(fields.href, "/xyz.html")
        XCTAssertEqual(fields.progression, 0.666)
    }

    /// What we write must be readable by our own parser as the same position
    /// we wrote — the round trip the sync prompt depends on.
    func testWrittenPosition_RoundTripsThroughOurOwnParser() throws {
        let publication = Self.makeTestPublication()
        let written = try locationString(for: Self.midChapterLocator(),
                                         publication: publication)
        let fields = try XCTUnwrap(EPUBPositionDialect(jsonString: written))

        XCTAssertEqual(fields.href, "/chapter1.xhtml")
        XCTAssertEqual(fields.progression, 0.62)
        XCTAssertEqual(fields.totalProgression, 0.17)
        XCTAssertEqual(fields.position, 58)
    }

    // MARK: - Backwards compatibility with positions already on the server

    /// Shipped versions wrote the Readium shape. Those positions are on the
    /// server now, and tapping "Move" on one must still land the patron where
    /// they left off rather than at the top of the chapter.
    func testLegacyReadiumPayload_ConvertsBackToThePostedPosition() async throws {
        let publication = Self.makeTestPublication()
        let locator = Self.midChapterLocator()
        let legacy = try locator.jsonString()

        let serverLocation = try XCTUnwrap(
            TPPBookLocation(locationString: legacy,
                            renderer: TPPBookLocation.r3Renderer)
        )
        let converted = await serverLocation.convertToLocator(publication: publication)
        let restored = try XCTUnwrap(converted,
                                     "convertToLocator must resolve a locator from legacy bytes")

        XCTAssertEqual(restored.locations.totalProgression, locator.locations.totalProgression)
        XCTAssertEqual(restored.locations.progression, locator.locations.progression)
        XCTAssertEqual(restored.locations.position, locator.locations.position)
    }

    /// A device still holding a legacy Readium-shaped position locally, whose
    /// server copy is now spec-shaped, is on the SAME page. It must not be
    /// prompted to sync with itself during the changeover.
    func testLegacyAndSpecShapes_OfTheSamePage_DoNotPrompt() throws {
        let publication = Self.makeTestPublication()
        let locator = Self.midChapterLocator()

        let specShaped = try locationString(for: locator, publication: publication)
        let legacyShaped = try locator.jsonString()

        XCTAssertFalse(
            TPPLastReadPositionSynchronizer.shouldPresentServerPosition(
                serverDevice: "device-A",
                serverLocationString: specShaped,
                localLocationString: legacyShaped,
                drmDeviceID: "device-B"
            ),
            "the same page in the legacy and spec shapes must not produce a prompt"
        )
    }

    /// The other side of the rule: a real cross-device difference must still
    /// prompt, or a fix that suppresses everything would pass.
    func testDifferentPage_OnAnotherDevice_StillPromptsToSync() throws {
        let publication = Self.makeTestPublication()
        let local = try locationString(for: Self.midChapterLocator(),
                                       publication: publication)
        let elsewhere = try locationString(
            for: Locator(
                href: AnyURL(string: "/chapter1.xhtml")!,
                mediaType: .xhtml,
                title: "Chapter One",
                locations: Locator.Locations(progression: 0.9,
                                             totalProgression: 0.55,
                                             position: 190)
            ),
            publication: publication
        )

        XCTAssertTrue(
            TPPLastReadPositionSynchronizer.shouldPresentServerPosition(
                serverDevice: "device-A",
                serverLocationString: elsewhere,
                localLocationString: local,
                drmDeviceID: "device-B"
            ),
            "a position from another device on a different page must still be offered"
        )
    }

    // MARK: - Fixtures

    /// A patron partway through chapter 1: 62% into the chapter, 17% into the
    /// book, page 58.
    private nonisolated static func midChapterLocator() -> Locator {
        Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            title: "Chapter One",
            locations: Locator.Locations(
                progression: 0.62,
                totalProgression: 0.17,
                position: 58
            )
        )
    }

    private nonisolated static func makeTestPublication() -> Publication {
        let metadata = Metadata(title: "Test", languages: ["en"])
        let readingOrder = [Link(href: "/chapter1.xhtml", mediaType: .xhtml)]
        return Publication(manifest: Manifest(metadata: metadata, readingOrder: readingOrder))
    }
}
