//
//  AudiobookPositionResolverDecisionTableTests.swift
//  PalaceTests
//
//  Wave 6 decomposition pin for `Palace/Audiobooks/AudiobookSessionManager.swift`
//  (god-class-decomposition-plan.md §3a-1 "Position resolve before play,
//  PP-4542 + position restoration helpers → `AudiobookPositionResolver`"; §5
//  fleet row names "position-resolution decision table (local vs remote vs none
//  — the PP-4542 cases)").
//
//  WHAT THIS PINS THAT `AudiobookPositionRestoreTests` DOES NOT
//
//  That suite pins the two rules SEPARATELY and thoroughly: the >5s recency
//  comparison (`preferRemotePosition`, 7 cases) and the manifest gate applied to
//  a remote (`validatedRemotePosition`, 2 cases). What it cannot reach is their
//  COMPOSITION, because the composition lived inside `resolveInitialPosition`,
//  which interleaved them with a bounded `syncLocation` await against a concrete
//  `TPPBookRegistry` — so driving it needed a live registry and a 2.5s timer.
//
//  The extraction stops that await at `awaitRemotePosition` and leaves
//  `chooseInitialPosition(remote:localPosition:fallback:in:bookId:)` pure, which
//  makes the composition a finite table: {no remote, remote older, remote newer
//  and valid, remote newer and foreign-keyed} × {no local, local present}. Every
//  cell resolves to either the fallback or the remote, and getting a cell wrong
//  is a patron opening at the wrong place in a book — the PP-4542 / 3.2.3
//  Cause 2 failure class.
//
//  WHY THE TABLE IS 6 CELLS AND NOT 8. `localPosition` is only read by the
//  recency comparison, which is only reached when a remote exists. So the
//  no-remote row collapses to one cell for both local states, and that
//  collapse is itself asserted (`testNoRemote_*`) rather than assumed.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceBookModel

@MainActor
final class AudiobookPositionResolverDecisionTableTests: XCTestCase {

    private let bookIdentifier = "urn:test:audiobook"
    private let manifestJSON: ManifestJSON = .snowcrash
    private var registryMock: TPPBookRegistryMock!
    private var sut: AudiobookPositionResolver!
    private var tracks: Tracks!
    private var toc: AudiobookTableOfContents!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registryMock = TPPBookRegistryMock()
        sut = AudiobookPositionResolver(bookRegistry: registryMock)

        let manifest = try Manifest.from(
            jsonFileName: manifestJSON.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: nil)
        toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

        // Fixture sanity: a single-track manifest would make "a different track"
        // unconstructible and several cells below vacuous.
        XCTAssertGreaterThanOrEqual(tracks.tracks.count, 3,
            "snowcrash fixture must have ≥3 tracks for the remote-vs-local cells to differ")
    }

    override func tearDownWithError() throws {
        sut = nil
        registryMock = nil
        tracks = nil
        toc = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func position(trackIndex: Int, timestamp: TimeInterval, savedAt: String) -> TrackPosition {
        var p = TrackPosition(
            track: tracks.tracks[trackIndex],
            timestamp: timestamp,
            tracks: tracks
        )
        p.lastSavedTimeStamp = savedAt
        return p
    }

    /// A position on a track whose key is NOT in the loaded manifest — the
    /// 3.2.3 Cause 2 shape (a saved key the manifest no longer contains).
    private func foreignKeyedPosition(savedAt: String) throws -> TrackPosition {
        let manifest = try Manifest.from(
            jsonFileName: manifestJSON.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        let foreign = try OpenAccessTrack(
            manifest: manifest,
            urlString: "https://example.com/not-in-manifest.mp3",
            audiobookID: bookIdentifier,
            title: "Foreign Track",
            duration: 60,
            index: 999,
            token: nil,
            key: "FOREIGN-KEY-NOT-IN-MANIFEST"
        )
        var p = TrackPosition(track: foreign, timestamp: 10, tracks: tracks)
        p.lastSavedTimeStamp = savedAt
        return p
    }

    private let older = "2026-01-01T00:00:00Z"
    private let newer = "2026-01-01T00:01:00Z"   // +60s: past the >5s threshold

    private func choose(
        remote: TrackPosition?,
        local: TrackPosition?,
        fallback: TrackPosition
    ) -> TrackPosition {
        sut.chooseInitialPosition(
            remote: remote,
            localPosition: local,
            fallback: fallback,
            in: toc,
            bookId: bookIdentifier
        )
    }

    // MARK: - Row 1: no remote resolved (slow backend, no server bookmark)

    func testNoRemote_withLocal_opensAtFallback() {
        let local = position(trackIndex: 1, timestamp: 42, savedAt: older)
        let resolved = choose(remote: nil, local: local, fallback: local)
        XCTAssertEqual(resolved.track.key, local.track.key)
        XCTAssertEqual(resolved.timestamp, local.timestamp,
            "A bounded remote await that produced nothing must open at the saved local spot, not restart the book (PP-4542)")
    }

    func testNoRemote_withoutLocal_opensAtFallbackBeginning() {
        let beginning = position(trackIndex: 0, timestamp: 0, savedAt: older)
        let resolved = choose(remote: nil, local: nil, fallback: beginning)
        XCTAssertEqual(resolved.track.key, beginning.track.key)
        XCTAssertEqual(resolved.timestamp, 0,
            "No remote and no local means chapter 1 — the caller's fallback is returned untouched")
    }

    // MARK: - Row 2: remote present, not meaningfully newer

    func testRemoteOlderThanLocal_opensAtLocal() {
        let local = position(trackIndex: 1, timestamp: 42, savedAt: newer)
        let remote = position(trackIndex: 2, timestamp: 900, savedAt: older)
        let resolved = choose(remote: remote, local: local, fallback: local)
        XCTAssertEqual(resolved.track.key, local.track.key,
            "A stale server copy must not drag the patron backwards over a newer local save")
        XCTAssertEqual(resolved.timestamp, 42)
    }

    func testRemoteNewerByLessThanThreshold_opensAtLocal() {
        // +3s — inside the >5s window, so the local save still wins.
        let local = position(trackIndex: 1, timestamp: 42, savedAt: "2026-01-01T00:00:00Z")
        let remote = position(trackIndex: 2, timestamp: 900, savedAt: "2026-01-01T00:00:03Z")
        let resolved = choose(remote: remote, local: local, fallback: local)
        XCTAssertEqual(resolved.track.key, local.track.key,
            "Within the 5s tolerance the two saves are the same listening session; the local one is authoritative")
    }

    // MARK: - Row 3: remote newer and valid

    func testRemoteNewerAndInManifest_opensAtRemote() {
        let local = position(trackIndex: 1, timestamp: 42, savedAt: older)
        let remote = position(trackIndex: 2, timestamp: 900, savedAt: newer)
        let resolved = choose(remote: remote, local: local, fallback: local)
        XCTAssertEqual(resolved.track.key, remote.track.key,
            "A server save from another device, meaningfully newer and present in this manifest, is what the patron expects to resume at")
        XCTAssertEqual(resolved.timestamp, 900)
    }

    func testRemoteNewerWithNoLocal_opensAtRemote() {
        let beginning = position(trackIndex: 0, timestamp: 0, savedAt: older)
        let remote = position(trackIndex: 2, timestamp: 900, savedAt: newer)
        let resolved = choose(remote: remote, local: nil, fallback: beginning)
        XCTAssertEqual(resolved.track.key, remote.track.key,
            "With nothing saved locally any remote position beats starting over (preferRemotePosition returns true for a nil local)")
        XCTAssertEqual(resolved.timestamp, 900)
    }

    // MARK: - Row 4: remote newer but NOT in this manifest (3.2.3 Cause 2)

    func testRemoteNewerButForeignKeyed_opensAtFallbackNotRemote() throws {
        let local = position(trackIndex: 1, timestamp: 42, savedAt: older)
        let remote = try foreignKeyedPosition(savedAt: newer)
        let resolved = choose(remote: remote, local: local, fallback: local)
        XCTAssertEqual(resolved.track.key, local.track.key,
            "Seeking a track key the loaded manifest does not contain opens at a phantom position — the 3.2.3 Cause 2 failure. Newer is not sufficient; it must also validate")
        XCTAssertNotEqual(resolved.track.key, remote.track.key)
    }

    func testRemoteNewerButForeignKeyed_withNoLocal_opensAtBeginning() throws {
        let beginning = position(trackIndex: 0, timestamp: 0, savedAt: older)
        let remote = try foreignKeyedPosition(savedAt: newer)
        let resolved = choose(remote: remote, local: nil, fallback: beginning)
        XCTAssertEqual(resolved.track.key, beginning.track.key,
            "With no local save the manifest gate drops to chapter 1 rather than to an unresolvable remote key")
        XCTAssertEqual(resolved.timestamp, 0)
    }

    // MARK: - The gate reports which step dropped the position

    func testForeignKeyedRemote_logsTheFailureWithRemoteSource() throws {
        let spy = SpyAudiobookPositionLogger()
        sut.positionLogger = spy
        let local = position(trackIndex: 1, timestamp: 42, savedAt: older)
        let remote = try foreignKeyedPosition(savedAt: newer)
        _ = choose(remote: remote, local: local, fallback: local)

        XCTAssertEqual(spy.failures.count, 1,
            "Support triage greps [AUDIOPOS] FAIL for exactly this drop; a silent fallback is indistinguishable from the patron never having a remote save")
        XCTAssertEqual(spy.failures.first?.reason, "track_key_mismatch")
        XCTAssertEqual(spy.failures.first?.context["source"], "remote",
            "The remote and local paths share the validator, so the source tag is the only thing that tells a triager which side dropped")
    }

    func testAcceptedRemote_logsNoFailure() {
        let spy = SpyAudiobookPositionLogger()
        sut.positionLogger = spy
        let local = position(trackIndex: 1, timestamp: 42, savedAt: older)
        let remote = position(trackIndex: 2, timestamp: 900, savedAt: newer)
        _ = choose(remote: remote, local: local, fallback: local)
        XCTAssertTrue(spy.failures.isEmpty,
            "A position that was used must not be reported as dropped, or the triage signal is noise")
    }
}

// MARK: - Spy

/// Records `[AUDIOPOS]` emissions instead of routing them to `Log.warn`.
private final class SpyAudiobookPositionLogger: AudiobookPositionLogging {
    struct Emission {
        let reason: String
        let context: [String: String]
    }
    private(set) var failures: [Emission] = []
    private(set) var fallbacks: [Emission] = []

    func logFailure(reason: String, context: [String: String]) {
        failures.append(Emission(reason: reason, context: context))
    }

    func logFallback(reason: String, context: [String: String]) {
        fallbacks.append(Emission(reason: reason, context: context))
    }
}
