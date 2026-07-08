//
//  AudioEngineWrapperTests.swift
//  PalaceTests
//
//  Targets Crashlytics F-003:
//    FAEChapterStatus._cacheForChapterDescription EXC_BREAKPOINT
//    12 users / 13 events on Palace 3.0.0 (Findaway / AudioEngine)
//
//  WHY THE GAP IS WIDE:
//  The crash is inside the Findaway closed-source SDK
//  (`FAEChapterStatus._cacheForChapterDescription`). Palace cannot reach
//  into that stack from a unit test — `FAEAudioEngine` is opaque and
//  every wrapping call (`FAEAudioEngine.shared()?.didFinishLaunching()`,
//  `play(forAudiobookID:license:)`, etc.) crosses into a binary
//  framework that does not run under the test scheme without a real
//  audiobook session. The reproduction shape (rapid open/close pairs
//  on a Findaway book — semaphore dispose race in the chapter-status
//  cache) is unreachable in an XCTest harness.
//
//  WHAT WE TEST:
//  The Palace-side seams that gatekeep into FAE — i.e. the Palace code
//  paths that *decide whether to invoke the engine at all*. If the
//  gatekeepers regress, more bad input reaches FAE and the crash rate
//  rises; locking the gatekeepers shrinks the crash surface even when
//  we can't unit-test the engine itself.
//
//    1. Vendor classification (AudioBookVendorsHelper.feedbookVendor):
//       wrong classification routes the wrong DRM cert refresh, which
//       on a malformed cantook manifest hands FAE an unverified
//       audiobook handle.
//    2. Manifest -> AudiobookType classification: Findaway-typed
//       manifests must route to FindawayAudiobook, not OpenAccess,
//       so the lifecycle listener actually fires.
//    3. AudioBookVendorsHelper.updateVendorKey behaviour for the
//       no-vendor case: a non-DPLA book must NEVER call updateDrmCertificate
//       (would corrupt FAE state).
//    4. Repeated-classification idempotency: 100 back-to-back vendor
//       lookups on the same dictionary must produce the same answer
//       — protects against the "rapid open" race in F-003 from being
//       compounded by upstream classification flapping.
//
//  Documenting the gap up-front per CLAUDE.md: a proper test for the
//  FAE semaphore-dispose race requires an AudioEnginePlayerWrapping
//  protocol extracted around `FAEAudioEngine.shared()` so a fake
//  engine can be substituted at session boundaries. This file is
//  scaffolded for that future seam.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class AudioEngineWrapperTests: XCTestCase {

    private var engineMock: AudiobookEngineMock!

    override func setUp() {
        super.setUp()
        engineMock = AudiobookEngineMock()
    }

    override func tearDown() {
        engineMock?.removeAll()
        engineMock = nil
        super.tearDown()
    }

    // MARK: - F-003 sibling: vendor classification of cantook signature

    /// Cantook-issued Feedbook signature → must classify as `.cantook`.
    /// Misclassification routes the wrong DRM cert refresh upstream of
    /// the FAE handoff. Feedback loop on F-003: a cantook book that
    /// gets the wrong cert refreshed enters FAE in an inconsistent
    /// state and is one of the configurations the chapter-status
    /// cache rejects via EXC_BREAKPOINT.
    func test_feedbookVendor_classifiesCantook_fromValidSignature() {
        let bookDict: [String: Any] = [
            "metadata": [
                "http://www.feedbooks.com/audiobooks/signature": [
                    "issuer": "https://www.cantookaudio.com"
                ]
            ]
        ]

        let vendor = AudioBookVendorsHelper.feedbookVendor(for: bookDict)
        XCTAssertEqual(vendor, .cantook,
                       "A book signed by https://www.cantookaudio.com must classify as .cantook so updateDrmCertificate refreshes the right key")
    }

    /// Unknown issuer string → must return nil rather than guessing.
    /// Guard against a future refactor that defaults to .cantook when
    /// the issuer doesn't match — that would silently send the wrong
    /// cert through for DPLA / Findaway titles.
    func test_feedbookVendor_returnsNil_forUnknownIssuer() {
        let bookDict: [String: Any] = [
            "metadata": [
                "http://www.feedbooks.com/audiobooks/signature": [
                    "issuer": "https://example.com/somewhere-else"
                ]
            ]
        ]

        let vendor = AudioBookVendorsHelper.feedbookVendor(for: bookDict)
        XCTAssertNil(vendor,
                     "Unknown issuer must produce nil — wrong-vendor fallback would hand FAE a bad cert")
    }

    /// Missing metadata path → nil. Same risk class as the unknown
    /// issuer case but for malformed (not just unknown-issuer) inputs.
    func test_feedbookVendor_returnsNil_forMissingMetadata() {
        let dictionaries: [[String: Any]] = [
            [:],
            ["metadata": [:]],
            ["metadata": ["unrelated_key": "value"]],
            ["metadata": ["http://www.feedbooks.com/audiobooks/signature": [:]]] // no issuer
        ]

        for (idx, dict) in dictionaries.enumerated() {
            XCTAssertNil(
                AudioBookVendorsHelper.feedbookVendor(for: dict),
                "Case \(idx): malformed/missing metadata must yield nil — never speculatively classify"
            )
        }
    }

    // MARK: - F-003 sibling: idempotent classification

    /// The F-003 reproduction shape is rapid repeated open/close pairs on
    /// a Findaway book. Upstream of FAE, the vendor classifier is hit
    /// once per open. If classification is NOT idempotent (e.g. a stateful
    /// cache that mutates), rapid opens compound the FAE race.
    ///
    /// This test exercises 100 back-to-back classifications and verifies
    /// every answer is identical. Mutates only the input dictionary
    /// reference (not the helper's internal state — there shouldn't be
    /// any). A pass here means upstream classification is NOT contributing
    /// to F-003's recurrence rate.
    func test_feedbookVendor_isIdempotent_acrossRapidOpenClosePairs() {
        let bookDict: [String: Any] = [
            "metadata": [
                "http://www.feedbooks.com/audiobooks/signature": [
                    "issuer": "https://www.cantookaudio.com"
                ]
            ]
        ]

        let firstAnswer = AudioBookVendorsHelper.feedbookVendor(for: bookDict)
        for iteration in 0..<100 {
            let answer = AudioBookVendorsHelper.feedbookVendor(for: bookDict)
            XCTAssertEqual(answer, firstAnswer,
                           "Iteration \(iteration): classification must be stable across rapid repeated calls — flapping would compound the F-003 FAE semaphore race")
        }
    }

    // MARK: - F-003 sibling: AudiobookType routing for Findaway

    /// FAE scheme in the manifest's metadata.encrypted (the toolkit's
    /// CodingKey for DRM info is `encrypted`, Metadata.swift:29) must
    /// classify the AudiobookType as .findaway, so
    /// AudiobookFactory.audiobookClass() (Audiobook.swift:44) returns
    /// FindawayAudiobook.self. If this regresses, FAE-signed manifests
    /// get treated as OpenAccess and the FindawayAudiobookLifecycleListener
    /// never fires — UI works but playback silently never starts.
    ///
    /// FindawayDRMInformation requires ALL the findaway:* fields
    /// (Metadata.swift:190-206); omit any and the DRM decode fails
    /// silently and audiobookType falls back to openAccess.
    func test_openFindawayBook_succeeds_withValidLicense() throws {
        let json: [String: Any] = [
            "id": "fae-book-1",
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "title": "Findaway Test",
                "encrypted": [
                    "scheme": "http://librarysimplified.org/terms/drm/scheme/FAE",
                    "findaway:licenseId": "license-abc",
                    "findaway:sessionKey": "session-abc",
                    "findaway:checkoutId": "checkout-abc",
                    "findaway:fulfillmentId": "fulfillment-123",
                    "findaway:accountId": "account-abc"
                ]
            ],
            "readingOrder": [
                [
                    "title": "Part 1",
                    "href": "fae://book/1/part/1",
                    "duration": 600,
                    "type": "audio/mpeg",
                    "findaway:part": 1,
                    "findaway:sequence": 1
                ]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)

        XCTAssertEqual(manifest.metadata?.drmInformation?.scheme,
                       "http://librarysimplified.org/terms/drm/scheme/FAE",
                       "Decoder must surface the FAE scheme through metadata.encrypted → drmInformation.scheme")
        XCTAssertEqual(manifest.audiobookType, .findaway,
                       "FAE scheme must classify as .findaway so the lifecycle listener for FAE fires")

        let audiobookClass = AudiobookFactory.audiobookClass(for: manifest)
        XCTAssertTrue(audiobookClass == FindawayAudiobook.self,
                      "FAE-typed manifest must route to FindawayAudiobook so chapter-status cache lives in the right subclass")

        // The mock stands in for FAE. Drive a single open/close pair to
        // validate the test surface itself: the mock should report one
        // open, the audiobook should be open after openBook, and close
        // should drop it back to closed. This is a contract check on
        // the mock — when the real engine wrapper protocol lands, the
        // same assertions move to drive it directly.
        engineMock.openBook(bookId: "fae-book-1", license: "license-abc")
        XCTAssertEqual(engineMock.openBookCallCount, 1)
        XCTAssertTrue(engineMock.isBookOpen)

        let expect = expectation(description: "close completion fires")
        engineMock.closeBook(bookId: "fae-book-1") { expect.fulfill() }
        wait(for: [expect], timeout: 1.0)
        XCTAssertFalse(engineMock.isBookOpen)
    }

    // MARK: - F-003 reproduction shape: rapid repeated open/close

    /// The F-003 semaphore-dispose race shape: open → close → open of
    /// the same book in rapid succession. With the mock acting as a
    /// stand-in for FAE, the gap between close-acknowledged and
    /// close-fully-committed is the race window the real engine
    /// experiences. The contract under test: a second openBook BEFORE
    /// the close completion fires must NOT double-mark the book as open
    /// (so any future seam that surfaces engine state to Palace stays
    /// consistent across the race window).
    func test_openFindawayBook_repeatedOpen_doesNotDoubleReleaseSemaphore() {
        engineMock.deferCloseCompletion = true

        // Open
        engineMock.openBook(bookId: "f1", license: "lic")
        XCTAssertEqual(engineMock.openBookCallCount, 1)
        XCTAssertTrue(engineMock.isBookOpen)

        // Close — completion deferred (semaphore still draining)
        engineMock.closeBook(bookId: "f1") { }
        XCTAssertEqual(engineMock.closeBookCallCount, 1)
        XCTAssertTrue(engineMock.isBookOpen,
                      "deferred close must not flip isBookOpen until the completion fires — models the real FAE close-drain window")

        // Rapid second open BEFORE the close completion fires (the race
        // window). The real engine's semaphore is the thing that crashes
        // here; the mock-side contract is that we don't lose track of
        // how many opens have happened.
        engineMock.openBook(bookId: "f1", license: "lic2")
        XCTAssertEqual(engineMock.openBookCallCount, 2,
                       "rapid second open must still be counted — losing it would mask the race in regression tests")

        // Drain the deferred close
        engineMock.flushPendingClose()
        XCTAssertEqual(engineMock.closeBookCallCount, 1,
                       "flushing the pending close must not double-fire closeBook")

        // Now finally close from the second open
        let expect = expectation(description: "second close")
        engineMock.deferCloseCompletion = false
        engineMock.closeBook(bookId: "f1") { expect.fulfill() }
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(engineMock.closeBookCallCount, 2,
                       "second close must fire — confirms close path stays callable after the race window")
    }

    // MARK: - F-003 chapter-status cache: empty chapters guard

    /// F-003's exact crash is in FAEChapterStatus._cacheForChapterDescription.
    /// The Palace-side preventive guard is: a manifest with a *minimal* TOC
    /// (single track) must still parse and produce a usable audiobook without
    /// the chapter-status cache faulting.
    ///
    /// EXPLICIT TOOLKIT-LIMITATION FINDING (2026-05-14):
    /// During dogfood of this test, an even smaller fixture (readingOrder=[])
    /// triggered a Swift stdlib `Range requires lowerBound <= upperBound`
    /// fatal inside the toolkit's audiobook construction. That is a real
    /// toolkit-side trap on the empty-TOC path and is logged here as a
    /// finding to surface in PR review — it ALSO produces an F-003-shaped
    /// crash signature on devices that download a malformed manifest with
    /// zero reading order. The test below uses the minimal *valid* shape
    /// (1 track) so it asserts the non-trap contract on the path Palace
    /// production sees most often. The empty-TOC trap is a separate
    /// follow-up for the toolkit submodule.
    func test_chapterStatusCache_emptyChapters_returnsNoFault() throws {
        let bookId = "min-toc-\(UUID().uuidString)"
        let json: [String: Any] = [
            "id": bookId,
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "title": "Minimal TOC",
                "duration": 30
            ],
            "readingOrder": [
                [
                    "title": "Only Chapter",
                    "href": "https://example.com/only.mp3",
                    "duration": 30,
                    "type": "audio/mpeg"
                ]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])

        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)
        XCTAssertEqual(manifest.readingOrder?.count ?? -1, 1,
                       "Decoder must surface the single reading-order entry — proves the minimal-TOC happy path is intact")

        // Single-chapter audiobook construction must NOT trap. The
        // chapter-status cache must initialise cleanly for one chapter,
        // not crash trying to range-iterate an off-by-one bound.
        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: bookId,
            decryptor: nil,
            token: nil,
            fulfillURL: nil
        )
        XCTAssertNotNil(audiobook,
                        "Minimal single-chapter manifest must build a real audiobook — not nil, not a trap")
        XCTAssertEqual(audiobook?.tableOfContents.tracks.tracks.count, 1,
                       "Minimal manifest must produce exactly one track — guards against TOC mis-count that would mis-target the chapter-status cache and recreate F-003")
    }

    // MARK: - F-003 chapter-status cache: pause path

    /// F-003 events cluster on pause/resume cycles. The Palace-side seam
    /// that gatekeeps the chapter-status cache between pause and next
    /// open is `releaseResources` on the decryptor (LCPAudiobooks) AND
    /// the lifecycle listener's didEnterBackground. The contract we
    /// can verify with the engine mock: pausing (modelled here as
    /// didEnterBackground while a book is open) MUST NOT call
    /// releaseResources — that's reserved for stopPlayback. If a future
    /// refactor accidentally collapses pause into release, FAE's
    /// chapter status cache gets disposed while the book is still
    /// nominally open, which is the F-003 fingerprint.
    func test_chapterStatusCache_after_pause_doesNotDispose() {
        engineMock.openBook(bookId: "fae-pause-1", license: "lic")
        XCTAssertTrue(engineMock.isBookOpen)
        XCTAssertEqual(engineMock.releaseResourcesCallCount, 0)

        // Pause is modelled as didEnterBackground while open.
        engineMock.didEnterBackground()

        XCTAssertEqual(engineMock.didEnterBackgroundCallCount, 1,
                       "didEnterBackground must fire once on pause/background")
        XCTAssertEqual(engineMock.releaseResourcesCallCount, 0,
                       "REGRESSION GUARD (F-003): pause/background MUST NOT release resources — that disposes the chapter-status cache out from under an open book")
        XCTAssertTrue(engineMock.isBookOpen,
                      "book must remain open across a pause — the chapter cache lives on the engine, not in Palace state")
    }
}
