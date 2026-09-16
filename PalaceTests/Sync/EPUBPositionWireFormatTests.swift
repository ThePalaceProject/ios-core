//
//  EPUBPositionWireFormatTests.swift
//  PalaceTests
//
//  PP-5138: the EPUB reading position Palace POSTs to the annotation server
//  and the EPUB reading position Palace READS BACK from it are two different
//  JSON dialects. These tests pin the round trip at the byte level.
//
//  The write side (`TPPLastReadPositionPoster.makeSnapshot`) serializes the
//  Readium `Locator` verbatim — `{"href", "type", "title", "locations":{...}}`.
//  The read side (`TPPLastReadPositionSynchronizer.syncReadPosition`) wraps
//  the server bytes in a `TPPBookLocation` and calls `convertToLocator`, which
//  reads the FLAT `TPPBookLocation` dialect — `{"href", "@type",
//  "progressWithinChapter", "progressWithinBook", "position"}`.
//
//  Two user-visible consequences, both reported on PP-5138:
//   1. The "server and client have the same page" short-circuit compares the
//      two dialects as strings, so it can never be true — the sync prompt
//      fires on every open of every EPUB.
//   2. Tapping "Move" converts the server bytes through the wrong dialect,
//      so the within-chapter offset is dropped and the reader lands at the
//      top of the chapter — the position loss the reporter described as
//      "can cause a loss of position if the user clicks the wrong button".
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import ReadiumShared
@testable import Palace
import PalaceBookModel

// Deliberately NOT @MainActor — `Publication` / `TPPBookLocation` are
// non-Sendable and `convertToLocator` is `nonisolated async`, matching
// `EPUBPositionTests`.
final class EPUBPositionWireFormatTests: XCTestCase {

    /// The exact bytes `TPPLastReadPositionPoster` puts on the wire.
    /// Mirrors `makeSnapshot(from:)`: `try? locator.jsonString()`.
    private func postedSelectorValue(for locator: Locator) throws -> String {
        try locator.jsonString()
    }

    /// The exact bytes the book registry holds locally.
    /// Mirrors `storeReadPosition(locator:)`.
    private func localLocationString(for locator: Locator,
                                     publication: Publication) throws -> String {
        let location = try XCTUnwrap(
            TPPBookLocation(locator: locator,
                            type: "LocatorHrefProgression",
                            publication: publication),
            "TPPBookLocation(locator:) must not return nil for a mid-chapter locator"
        )
        return location.locationString
    }

    // MARK: - Consequence 1: the patron is prompted to sync with themselves

    /// The two dialects are NOT the same bytes, and deliberately so — the
    /// write side keeps posting Readium `Locator` JSON until it is unified
    /// with Android. This test pins that divergence so the read-side
    /// reconciliation below is understood as load-bearing rather than
    /// belt-and-braces: delete it and the byte comparison silently returns.
    func testWireFormats_LocalAndPostedAreDifferentDialects() throws {
        let publication = Self.makeTestPublication()
        let locator = Self.midChapterLocator()

        let posted = try postedSelectorValue(for: locator)
        let local = try localLocationString(for: locator, publication: publication)

        XCTAssertNotEqual(
            local, posted,
            "If these ever become byte-identical the write side has been unified; revisit the read-side reconciliation in EPUBPositionDialect"
        )
    }

    /// The reported bug. Device A posted this position; device B holds the
    /// identical position in the registry's dialect. Both devices are on the
    /// same page, so no sync prompt is warranted — the patron must not be
    /// asked to sync with themselves on every open.
    func testSamePage_InTwoDialects_DoesNotPromptToSync() throws {
        let publication = Self.makeTestPublication()
        let locator = Self.midChapterLocator()

        let posted = try postedSelectorValue(for: locator)
        let local = try localLocationString(for: locator, publication: publication)

        XCTAssertFalse(
            TPPLastReadPositionSynchronizer.shouldPresentServerPosition(
                serverDevice: "device-A",
                serverLocationString: posted,
                localLocationString: local,
                drmDeviceID: "device-B"
            ),
            """
            Both devices are on the identical page, so the sync prompt must be \
            suppressed. Comparing the two dialects as raw strings can never be \
            true, which is why the prompt never settled.
            local:  \(local)
            posted: \(posted)
            """
        )
    }

    /// The other side of the same rule: a genuine cross-device difference must
    /// still prompt. Without this, a fix that suppresses everything would pass.
    func testDifferentPage_OnAnotherDevice_StillPromptsToSync() throws {
        let publication = Self.makeTestPublication()
        let local = try localLocationString(for: Self.midChapterLocator(),
                                            publication: publication)
        let postedElsewhere = try postedSelectorValue(for: Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            title: "Chapter One",
            locations: Locator.Locations(progression: 0.9,
                                         totalProgression: 0.55,
                                         position: 190)
        ))

        XCTAssertTrue(
            TPPLastReadPositionSynchronizer.shouldPresentServerPosition(
                serverDevice: "device-A",
                serverLocationString: postedElsewhere,
                localLocationString: local,
                drmDeviceID: "device-B"
            ),
            "A position from another device on a different page must still be offered"
        )
    }

    // MARK: - Consequence 2: "Move" loses the within-chapter offset

    /// `syncReadPosition` builds `TPPBookLocation(locationString:
    /// serverLocationString, renderer: r3Renderer)` and calls
    /// `convertToLocator`. Feeding it the bytes production actually posts must
    /// recover the position that was posted — otherwise "Move" navigates the
    /// patron somewhere other than where they left off.
    func testMove_ServerBytesConvertBackToThePostedPosition() async throws {
        let publication = Self.makeTestPublication()
        let locator = Self.midChapterLocator()
        let posted = try postedSelectorValue(for: locator)

        let serverLocation = try XCTUnwrap(
            TPPBookLocation(locationString: posted,
                            renderer: TPPBookLocation.r3Renderer),
            "The synchronizer wraps the raw server bytes in a TPPBookLocation"
        )
        let converted = await serverLocation.convertToLocator(publication: publication)
        let restored = try XCTUnwrap(
            converted,
            "convertToLocator must resolve a locator from the posted bytes"
        )

        XCTAssertEqual(
            restored.locations.totalProgression, locator.locations.totalProgression,
            "Tapping Move must restore the posted book progression, not drop it"
        )
        XCTAssertEqual(
            restored.locations.progression, locator.locations.progression,
            "Tapping Move must restore the posted within-chapter progression — dropping it lands the patron at the top of the chapter"
        )
        XCTAssertEqual(
            restored.locations.position, locator.locations.position,
            "Tapping Move must restore the posted page position"
        )
    }

    // MARK: - Fixtures

    /// A patron partway through chapter 1: 62% into the chapter, 17% into the
    /// book, page 58. Every field here is one the reader needs back to land on
    /// the same page.
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
