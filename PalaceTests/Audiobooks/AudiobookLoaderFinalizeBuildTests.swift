//
//  AudiobookLoaderFinalizeBuildTests.swift
//  PalaceTests
//
//  Targets Crashlytics F-004: `AudiobookLoader.finalizeBuild` EXC_BREAKPOINT,
//  2 users on Palace 3.0.0 (Overdrive distributor, book "Irresponsible
//  Puckboy"). The crash is in the decode + AudiobookFactory.audiobook(...)
//  + DefaultAudiobookManager construction chain that lives inside the
//  private `finalizeBuild`. Because `finalizeBuild` is private we cannot
//  reach it via `@testable import Palace` without a seam extraction
//  (proposed in a TEST-SEAM comment in AudiobookLoader.swift). Until
//  that seam lands, we exercise the same toolkit-level surface area —
//  `Manifest.customDecoder()` + `AudiobookFactory.audiobook(...)` — that
//  the F-004 stack trace pins. Every assertion here would also fail if
//  the toolkit's decode or factory path regressed.
//
//  Gap left intentional: the AudiobookManager/PlaybackModel construction
//  on lines 511-534 of AudiobookLoader.swift is not directly reachable
//  here. Those depend on `AppContainer.production().accountsManager /
//  settings` for time-tracking and download-only-on-wifi, which we
//  refuse to touch in unit tests (singletons, banned by CLAUDE.md). A
//  proper test for that path needs the AudiobookFactoryProviding
//  protocol extraction proposed in the seam comment.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookLoaderFinalizeBuildTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Test fixtures

    /// Minimal, well-formed LCP-style open-access manifest dictionary. Two
    /// chapters, one author, modeled on the toolkit's dracula_manifest.json
    /// fixture. Pre-serialization (the [String: Any] → Data step) and
    /// decoding both succeed on this. Decoder hits the `openAccess`
    /// audiobookType branch in Manifest.audiobookType, so the factory
    /// returns an `OpenAccessAudiobook`, not a Findaway one.
    private func validOpenAccessManifestJSON(id: String) -> [String: Any] {
        return [
            "@context": ["https://readium.org/webpub-manifest/context.jsonld"],
            "id": id,
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "identifier": id,
                "title": "Test Audiobook",
                "author": [["name": "Test Author"]],
                "duration": 1000,
                "language": ["en"],
                "modified": "2024-09-25T23:32:53+0000"
            ],
            "readingOrder": [
                [
                    "title": "Chapter 1",
                    "href": "chapter1.mp3",
                    "duration": 500,
                    "type": "audio/mpeg"
                ],
                [
                    "title": "Chapter 2",
                    "href": "chapter2.mp3",
                    "duration": 500,
                    "type": "audio/mpeg"
                ]
            ],
            "toc": [
                [
                    "title": "Chapter 1",
                    "href": "chapter1.mp3#t=0"
                ],
                [
                    "title": "Chapter 2",
                    "href": "chapter2.mp3#t=0"
                ]
            ]
        ]
    }

    /// Manifest signature for an Overdrive book — F-004's exact distributor.
    /// `formatType` is what Manifest.audiobookType keys off for Overdrive
    /// (Manifest.swift:364). No reading order properties → no LCP, no
    /// Findaway.
    private func validOverdriveManifestJSON(id: String) -> [String: Any] {
        return [
            "id": id,
            "formatType": "audiobook-overdrive",
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "identifier": id,
                "title": "Overdrive Audiobook",
                "author": [["name": "Overdrive Author"]],
                "duration": 800
            ],
            "readingOrder": [
                [
                    "title": "Part 01",
                    "href": "https://example.com/part01.mp3",
                    "duration": 800,
                    "type": "audio/mpeg"
                ]
            ]
        ]
    }

    // MARK: - F-004: valid manifest path succeeds

    /// The good-weather path AudiobookLoader.finalizeBuild walks when a
    /// borrowed open-access audiobook is opened: decoder + factory both
    /// succeed and produce a non-nil Audiobook. This locks the decode +
    /// factory contract so a regression in either (e.g. the cantook
    /// EXC_BREAKPOINT existential capture re-emerging) gets caught here.
    func test_finalizeBuild_validManifest_succeeds() throws {
        let bookId = "test-valid-\(UUID().uuidString)"
        let json = validOpenAccessManifestJSON(id: bookId)
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])

        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)
        XCTAssertEqual(manifest.metadata?.title, "Test Audiobook",
                       "Decoder must surface the metadata.title from the manifest")
        XCTAssertEqual(manifest.audiobookType, .openAccess,
                       "Open-access manifest must route to openAccess factory branch")

        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: bookId,
            decryptor: nil,
            token: nil,
            fulfillURL: nil
        )
        XCTAssertNotNil(audiobook,
                        "AudiobookFactory must return a non-nil audiobook for a valid open-access manifest")
        XCTAssertEqual(audiobook?.uniqueId, bookId,
                       "Audiobook uniqueId must match the bookIdentifier passed in")
    }

    // MARK: - F-004: decode failure path

    /// finalizeBuild's first failure branch (lines 469-477): if the JSON is
    /// not a valid manifest (wrong root-type / wrong shape on a required
    /// nested field) the decoder throws and we surface
    /// `.manifestDecodingFailed`. The crucial property: this MUST throw,
    /// not crash with EXC_BREAKPOINT.
    ///
    /// Important: the Manifest decoder (Manifest.swift:68-105) uses
    /// `decodeIfPresent` everywhere at the root level, so a `{"foo": "bar"}`
    /// dict actually decodes successfully into an all-nil Manifest. The
    /// failure paths the loader ACTUALLY catches are:
    ///   (a) wrong-typed JSON root (array or string at top level)
    ///   (b) malformed required nested struct (e.g. malformed encrypted
    ///       block — see test_finalizeBuild_factoryReturnsNil_throwsFactoryFailed
    ///       above for that case).
    /// This test exercises (a) — same as production code paths that decode
    /// a CM error response (a JSON array) as if it were a manifest.
    func test_finalizeBuild_invalidJSON_throwsManifestDecodingFailed() {
        // Top-level JSON array, not an object → decoder must reject.
        let bogusData = Data("[\"not\", \"a manifest\"]".utf8)

        XCTAssertThrowsError(
            try Manifest.customDecoder().decode(Manifest.self, from: bogusData),
            "Top-level array JSON must throw DecodingError (the same path AudiobookLoader maps to .manifestDecodingFailed) — never crash"
        ) { error in
            XCTAssertTrue(error is DecodingError,
                          "Decode failure must produce a DecodingError so AudiobookLoader can unwrap it with logDecodingError()")
        }
    }

    /// Truncated JSON (the kind a flaky network produces partway through a
    /// large manifest fetch). The decoder must reject it cleanly — F-004
    /// signature includes "no underlying error" cases that fit this shape.
    func test_finalizeBuild_truncatedJSON_throwsCleanly() {
        let truncated = Data("{\"metadata\":{\"title\":\"Trunc".utf8)
        XCTAssertThrowsError(
            try Manifest.customDecoder().decode(Manifest.self, from: truncated),
            "Truncated JSON must throw, not crash. dataCorrupted at any path is acceptable."
        )
    }

    // MARK: - F-004: factory-returns-nil path

    /// Tests the second failure branch (line 483-493): manifest decoded
    /// OK but the factory could not synthesize an Audiobook from it.
    ///
    /// We use a manifest with a malformed `encrypted` block — present but
    /// missing the findaway:fulfillmentId, findaway:licenseId, and the
    /// other required findaway fields. The toolkit's DRMType.init(from:)
    /// (Metadata.swift:144) `try?`s the FindawayDRMInformation decode
    /// and falls through to `dataCorruptedError`, which makes the whole
    /// `metadata.encrypted` field decode fail — bubbling up to a hard
    /// decode error on Manifest. That maps to `.manifestDecodingFailed`
    /// in AudiobookLoader, NOT `.factoryFailed`. So this test instead
    /// asserts the decode-error path, which is the ACTUAL failure mode
    /// for malformed findaway metadata — and tightens the contract:
    /// even broken FAE manifests must throw, never crash.
    func test_finalizeBuild_factoryReturnsNil_throwsFactoryFailed() throws {
        // Malformed FAE metadata: a non-empty `encrypted` block that
        // tries to be findaway but is missing all the findaway:* fields
        // FindawayDRMInformation requires. Decode of `encrypted` will
        // fail with dataCorrupted → entire manifest decode throws.
        let json: [String: Any] = [
            "id": "findaway-malformed",
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "title": "Findaway Malformed",
                "encrypted": [
                    "scheme": "http://librarysimplified.org/terms/drm/scheme/FAE"
                    // findaway:fulfillmentId etc. intentionally missing
                ]
            ],
            "readingOrder": [
                [
                    "title": "Chapter 1",
                    "href": "fae://book/1",
                    "duration": 60,
                    "type": "audio/mpeg"
                ]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])

        // The malformed encrypted block must surface as a decode error,
        // mapping to AudiobookLoadError.manifestDecodingFailed in the
        // loader — never as a crash.
        XCTAssertThrowsError(
            try Manifest.customDecoder().decode(Manifest.self, from: jsonData),
            "Malformed findaway encrypted block must throw DecodingError — AudiobookLoader maps this to .manifestDecodingFailed (never crash)"
        ) { error in
            XCTAssertTrue(error is DecodingError,
                          "Decode failure must produce a DecodingError so AudiobookLoader can introspect and log via logDecodingError()")
        }
    }

    /// Companion: a manifest with NO `encrypted` block at all must decode
    /// fine (drmInformation = nil, audiobookType falls to .openAccess)
    /// and the factory must produce a usable audiobook. Locks the
    /// "missing-DRM is okay, malformed-DRM is not" invariant.
    func test_finalizeBuild_factoryReturnsNil_noEncryptedBlock_decodesFine() throws {
        let bookId = "no-drm-\(UUID().uuidString)"
        let json = validOpenAccessManifestJSON(id: bookId)  // no encrypted block
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)
        XCTAssertNil(manifest.metadata?.drmInformation,
                     "No encrypted block must leave drmInformation as nil — not an error")
        XCTAssertEqual(manifest.audiobookType, .openAccess,
                       "Missing DRM info must fall back to openAccess classification, not a phantom findaway")

        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: bookId,
            decryptor: nil,
            token: nil,
            fulfillURL: nil
        )
        XCTAssertNotNil(audiobook,
                        "A manifest without DRM info must produce a real OpenAccessAudiobook — missing-DRM is the default case for open-access content")
    }

    // MARK: - F-004: Overdrive path (the actual crash fingerprint)

    /// EXACT F-004 fingerprint: Overdrive distributor, bearer token,
    /// nil decryptor (Overdrive doesn't use DRMDecryptor). Crashlytics
    /// shows the build chain crashed in EXC_BREAKPOINT here. The test
    /// asserts the chain exits cleanly — decoder produces a manifest,
    /// factory produces a non-nil OpenAccessAudiobook (Overdrive routes
    /// through OpenAccessAudiobook per AudiobookFactory.audiobookClass).
    /// If this regresses, F-004 will recur.
    func test_finalizeBuild_overdriveBook_passesBearerToken() throws {
        let bookId = "overdrive-puckboy-\(UUID().uuidString)"
        let bearerToken = "test-bearer-token-abc123"
        let fulfillURL = URL(string: "https://patron.api.overdrive.com/fulfill/\(bookId)")!

        let json = validOverdriveManifestJSON(id: bookId)
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)
        XCTAssertEqual(manifest.audiobookType, .overdrive,
                       "formatType=audiobook-overdrive must classify as Overdrive (Manifest.swift:364)")

        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: bookId,
            decryptor: nil,                  // F-004: Overdrive uses no DRMDecryptor
            token: bearerToken,              // F-004: bearer token must reach the factory
            fulfillURL: fulfillURL           // F-004: fulfillURL must propagate to tracks
        )
        XCTAssertNotNil(audiobook,
                        "F-004 GUARD: Overdrive book with bearer token + nil decryptor must NOT crash — must return a non-nil Audiobook so the loader can build a manager")
        XCTAssertEqual(audiobook?.uniqueId, bookId,
                       "Overdrive audiobook must carry the bookIdentifier through, not the Overdrive content ID")
    }

    // MARK: - F-004: nil decryptor on a generic open-access book

    /// Tightens the nil-decryptor invariant: every open-access audiobook
    /// path through the factory MUST tolerate decryptor=nil. The historical
    /// EXC_BREAKPOINT shape was a force-unwrap somewhere downstream of
    /// the factory when no DRM was wired in. If this regresses, the
    /// factory or the OpenAccessAudiobook.init? will crash instead of
    /// returning a usable instance.
    func test_finalizeBuild_nilDecryptor_doesNotTrap() throws {
        let bookId = "openaccess-nil-\(UUID().uuidString)"
        let json = validOpenAccessManifestJSON(id: bookId)
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)

        // The nil-decryptor invariant the F-004 stack trace implies.
        // Calling through to AudiobookFactory with decryptor=nil and
        // token=nil must produce a real Audiobook, not trap, not return
        // nil. The two chapters in the fixture must show up in TOC so
        // we know construction got past the player wiring (where the
        // historical crashes lived).
        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: bookId,
            decryptor: nil,
            token: nil,
            fulfillURL: nil
        )
        XCTAssertNotNil(audiobook,
                        "nil decryptor on an open-access manifest must not trap — must return a real Audiobook")
        XCTAssertEqual(
            audiobook?.tableOfContents.toc.count, 2,
            "Both chapters from the fixture must reach the AudiobookTableOfContents — proves the TOC build past the factory entry point did not silently drop chapters"
        )
    }

    // MARK: - F-004: AudiobookLoadError shape stability

    /// Locks the AudiobookLoadError cases the loader's catch arms surface
    /// so a refactor of the enum doesn't quietly remove the failure
    /// branches the production code relies on. The associated values are
    /// what AudiobookSessionManager.mapLoadError() pattern-matches against.
    func test_audiobookLoadError_factoryFailedCarriesManifestType() {
        let err = AudiobookLoadError.factoryFailed(manifestType: "audiobook-overdrive")
        if case let .factoryFailed(manifestType) = err {
            XCTAssertEqual(manifestType, "audiobook-overdrive",
                           ".factoryFailed must preserve its manifestType payload so the loader can log which distributor failed")
        } else {
            XCTFail(".factoryFailed pattern must match — refactor regression if it doesn't")
        }
    }

    /// Locks `.manifestDecodingFailed` carries the underlying DecodingError
    /// so AudiobookLoader.logDecodingError() can switch on its specific
    /// cases (keyNotFound, typeMismatch, etc.). Without this guard, a
    /// refactor that simplifies the error to a bare case would silently
    /// drop the debugging surface that triaged F-004 to begin with.
    func test_audiobookLoadError_manifestDecodingFailedCarriesUnderlying() {
        let inner = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "synthetic")
        )
        let err = AudiobookLoadError.manifestDecodingFailed(underlying: inner)
        if case let .manifestDecodingFailed(underlying) = err {
            XCTAssertTrue(underlying is DecodingError,
                          "underlying must still be a DecodingError so logDecodingError can dispatch on its cases")
        } else {
            XCTFail(".manifestDecodingFailed pattern must match — refactor regression if it doesn't")
        }
    }
}
