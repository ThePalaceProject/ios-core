//
//  BookmarkSpecConformanceTests.swift
//  PalaceTests
//
//  Runs the locator corpus from `ThePalaceProject/mobile-specs` — the same
//  fixtures the Android client runs — against this client's parser and
//  serializer.
//
//  PP-5138: the wire format drifted away from the spec and nothing failed,
//  because nothing was wired to fail. The spec was vendored (as the archived
//  predecessor repo, pinned at its first commit) and cited in a doc comment,
//  but no test loaded it. Meanwhile the reading position went out in the
//  Readium `Locator` shape, which matches no variant in the spec's schema, and
//  the Android client discarded every one.
//
//  The corpus is read from the working tree rather than the test bundle so
//  that it is always the submodule's current content, never a stale copy. A
//  missing corpus FAILS — it must never skip. A conformance suite that
//  quietly runs zero cases is the condition this file exists to prevent.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel
import ReadiumShared

final class BookmarkSpecConformanceTests: XCTestCase {

    // MARK: - Corpus location

    /// `mobile-specs/bookmarks`, resolved from this file's path so the suite
    /// follows the checkout rather than a build-time copy.
    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)            // …/PalaceTests/Sync/<this file>
            .deletingLastPathComponent()            // …/PalaceTests/Sync
            .deletingLastPathComponent()            // …/PalaceTests
            .deletingLastPathComponent()            // repo root
            .appendingPathComponent("mobile-specs/bookmarks")
    }

    private func fixture(_ name: String) throws -> String {
        let url = Self.corpusURL.appendingPathComponent(name)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("""
                Spec fixture \(name) is missing at \(url.path).
                The mobile-specs submodule is not checked out — run
                `git submodule update --init mobile-specs`. This is a failure and
                not a skip on purpose: a conformance suite that silently runs no
                cases is how the wire format drifted from the spec in the first
                place.
                """)
            throw CocoaError(.fileNoSuchFile)
        }
        return contents
    }

    // MARK: - The corpus is actually present

    /// Guards every other test in this file. If the corpus were absent, each
    /// case below would fail individually, but this one names the cause once.
    func testCorpus_IsCheckedOutAndNonEmpty() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: Self.corpusURL.path
        )
        let locatorFixtures = contents.filter { $0.hasPrefix("valid-locator-") }

        XCTAssertGreaterThanOrEqual(
            locatorFixtures.count, 4,
            "the spec corpus must be checked out at \(Self.corpusURL.path); found \(contents.count) file(s)"
        )
    }

    // MARK: - Every valid href/progression locator in the corpus parses

    /// `valid-locator-0.json` is the canonical `LocatorHrefProgression`. It is
    /// the shape an EPUB reading position travels in, and the shape Android
    /// both writes and requires.
    func testSpecCorpus_ValidHrefProgressionLocator_Parses() throws {
        let fields = try XCTUnwrap(
            EPUBPositionDialect(jsonString: try fixture("valid-locator-0.json")),
            "valid-locator-0.json must parse"
        )

        XCTAssertEqual(fields.href, "/xyz.html")
        XCTAssertEqual(fields.progression, 0.666)
    }

    /// The spec's own example of a complete reading-position annotation. We
    /// read the locator out of `target.selector.value`, which is where a real
    /// server annotation carries it.
    func testSpecCorpus_ValidBookmarkAnnotation_SelectorValueParses() throws {
        let annotation = try JSONSerialization.jsonObject(
            with: Data(try fixture("valid-bookmark-0.json").utf8)
        ) as? [String: Any]

        let target = try XCTUnwrap(annotation?["target"] as? [String: Any])
        let selector = try XCTUnwrap(target["selector"] as? [String: Any])
        let value = try XCTUnwrap(selector["value"] as? String)

        let fields = try XCTUnwrap(EPUBPositionDialect(jsonString: value),
                                   "the locator inside a spec bookmark must parse")
        XCTAssertEqual(fields.href, "/xyz.html")
        XCTAssertEqual(fields.progression, 0.666)
    }

    /// The motivation this client sends for a reading position must be the one
    /// the spec names. Android throws on an unrecognized motivation, and that
    /// throw empties the patron's whole bookmark list rather than skipping the
    /// one annotation.
    func testSpecCorpus_ReadingPositionMotivation_MatchesOurs() throws {
        let annotation = try JSONSerialization.jsonObject(
            with: Data(try fixture("valid-bookmark-0.json").utf8)
        ) as? [String: Any]

        XCTAssertEqual(
            annotation?["motivation"] as? String,
            TPPBookmarkSpec.Motivation.readingProgress.rawValue,
            "our reading-position motivation must be the spec's idling motivation"
        )
    }

    // MARK: - What we write conforms

    /// The end-to-end claim this suite exists to hold: the bytes this client
    /// puts on the wire satisfy the spec's `LocatorHrefProgression` schema —
    /// `@type`, `href` and `progressWithinChapter`, with the progression in
    /// the 0.0…1.0 the schema requires.
    func testOurSerializedPosition_SatisfiesTheSpecRequiredKeys() throws {
        let required = try Self.requiredKeysForHrefProgression()
        let written = try Self.ourSerializedPosition()

        for key in required {
            XCTAssertNotNil(written[key],
                            "the spec requires `\(key)` on a LocatorHrefProgression; our wire format omits it")
        }

        XCTAssertEqual(written["@type"] as? String, "LocatorHrefProgression")
        let progression = try XCTUnwrap(written["progressWithinChapter"] as? Double)
        XCTAssertTrue((0.0...1.0).contains(progression),
                      "the schema bounds progressWithinChapter to 0.0…1.0; Android throws outside it")
    }

    /// Reads the required-key list out of the spec's own schema rather than
    /// restating it here, so tightening the schema upstream tightens this test.
    private static func requiredKeysForHrefProgression() throws -> [String] {
        let url = corpusURL.appendingPathComponent("locatorSchema.json")
        let data = try Data(contentsOf: url)
        let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let alternatives = try XCTUnwrap(schema?["oneOf"] as? [[String: Any]])

        for alternative in alternatives {
            let properties = alternative["properties"] as? [String: Any]
            let typeSpec = properties?["@type"] as? [String: Any]
            let pattern = typeSpec?["pattern"] as? String ?? typeSpec?["const"] as? String
            if pattern == "LocatorHrefProgression" {
                return try XCTUnwrap(alternative["required"] as? [String])
            }
        }
        XCTFail("the schema no longer describes LocatorHrefProgression")
        return []
    }

    /// The serialized position this client produces, via the same call
    /// `TPPLastReadPositionPoster` makes.
    private static func ourSerializedPosition() throws -> [String: Any] {
        let location = try XCTUnwrap(
            TPPBookLocation(href: "/xyz.html",
                            type: "LocatorHrefProgression",
                            chapterProgression: 0.666,
                            totalProgression: 0.2,
                            title: "Chapter",
                            position: 12)
        )
        let data = try XCTUnwrap(location.locationString.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
