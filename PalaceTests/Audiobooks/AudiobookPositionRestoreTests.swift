//
//  AudiobookPositionRestoreTests.swift
//  PalaceTests
//
//  F-007 / PP-4542 — position-validation + candidate-selection coverage for
//  AudiobookSessionManager. PR #1028 introduced the stale-position-on-reborrow
//  hardening (validationFailure / fallback-to-most-recent-bookmark). The
//  changed lines shipped with a 0% mutation kill rate; these tests pin the
//  real decisions through the production seams (`validationFailure(for:in:)`,
//  `isValidPosition`, `selectMostRecentValidBookmark`, `isUserAuthenticated`)
//  with constructed TOC + registry + account fixtures — no live Audiobook /
//  player graph, so the audiobook toolkit's fragility does not leak in.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookPositionRestoreTests: XCTestCase {

    private let bookIdentifier = "pp4542-audiobook"
    private let manifestJSON: ManifestJSON = .snowcrash

    private var registryMock: TPPBookRegistryMock!
    private var appContainer: AppContainer!
    private var sut: AudiobookSessionManager!
    private var tracks: Tracks!
    private var toc: AudiobookTableOfContents!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registryMock = TPPBookRegistryMock()
        appContainer = makeTestAppContainer(bookRegistry: registryMock)
        sut = AudiobookSessionManager(appContainer: appContainer)

        let manifest = try Manifest.from(
            jsonFileName: manifestJSON.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: nil)
        toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

        // Fixture sanity: the manifest must yield a multi-track, in-manifest TOC,
        // otherwise the key-match / sort assertions below would be vacuous.
        XCTAssertGreaterThanOrEqual(tracks.tracks.count, 3,
                                    "snowcrash fixture must have ≥3 tracks for these tests to be meaningful")
    }

    override func tearDownWithError() throws {
        sut = nil
        appContainer = nil
        registryMock = nil
        tracks = nil
        toc = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Builds a `TPPBookLocation` (the on-disk generic-bookmark shape the
    /// registry stores) for `track` at `timestamp`, stamping a controllable
    /// `lastSavedTimeStamp`. Production reads it back via
    /// `locationStringDictionary()` → `AudioBookmark.create` → `TrackPosition`.
    private func makeBookmarkLocation(
        track: any Track,
        timestamp: TimeInterval,
        savedAt: String
    ) -> TPPBookLocation {
        var position = TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
        position.lastSavedTimeStamp = savedAt
        let bookmark = position.toAudioBookmark()
        bookmark.lastSavedTimeStamp = savedAt
        guard let location = bookmark.toTPPBookLocation() else {
            XCTFail("Failed to build TPPBookLocation fixture")
            return TPPBookLocation(locationString: "{}", renderer: "PalaceAudiobookToolkit")!
        }
        return location
    }

    /// An OpenAccessTrack whose `key` is deliberately NOT present in the
    /// manifest — used to drive the `trackKeyNotInManifest` failure path.
    private func makeForeignKeyedTrack() throws -> OpenAccessTrack {
        let manifest = try Manifest.from(
            jsonFileName: manifestJSON.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        return try OpenAccessTrack(
            manifest: manifest,
            urlString: "https://example.com/not-in-manifest.mp3",
            audiobookID: bookIdentifier,
            title: "Foreign Track",
            duration: 60,
            index: 999,
            token: nil,
            key: "FOREIGN-KEY-NOT-IN-MANIFEST"
        )
    }

    // MARK: - validationFailure(for:in:) — track-key match (line ~1311)

    /// A position whose track key IS in the manifest passes the track-key
    /// gate (the only remaining gate for an otherwise-valid position), so
    /// `validationFailure` returns nil. Pins the `!= nil` predicate: a
    /// mutation to `== nil` (mutant for line ~1311) would report a spurious
    /// `.trackKeyNotInManifest` for a key that IS present and fail here.
    func testValidationFailure_trackKeyInManifest_returnsNil() {
        let position = TrackPosition(track: tracks.tracks[0], timestamp: 100, tracks: tracks)
        XCTAssertNil(sut.validationFailure(for: position, in: toc),
                     "An in-manifest track key with a sane timestamp must validate (no failure)")
    }

    /// A position whose track key is NOT in the manifest must fail with
    /// `.trackKeyNotInManifest`. This is the inverse of the test above and
    /// is what kills the `!= nil` → `== nil` mutant: under the mutant, an
    /// absent key would be treated as "matches" and this assertion flips.
    func testValidationFailure_trackKeyNotInManifest_returnsTrackKeyFailure() throws {
        let foreign = try makeForeignKeyedTrack()
        let position = TrackPosition(track: foreign, timestamp: 100, tracks: tracks)
        guard let failure = sut.validationFailure(for: position, in: toc) else {
            XCTFail("A track key absent from the manifest must produce a validation failure")
            return
        }
        XCTAssertEqual(failure, .trackKeyNotInManifest(savedKey: "FOREIGN-KEY-NOT-IN-MANIFEST"),
                       "Absent key must surface as .trackKeyNotInManifest carrying the saved key")
    }

    // MARK: - isValidPosition (line ~1343)

    /// `isValidPosition` returns true exactly when `validationFailure == nil`.
    /// Valid position → true. Kills the `== nil` → `!= nil` mutant at line
    /// ~1343 (under the mutant a valid position would report invalid).
    func testIsValidPosition_validPosition_returnsTrue() {
        let position = TrackPosition(track: tracks.tracks[1], timestamp: 50, tracks: tracks)
        XCTAssertTrue(sut.isValidPosition(position, in: toc),
                      "A position with an in-manifest key and a finite, non-negative timestamp is valid")
    }

    /// Invalid position (negative timestamp) → false. The companion to the
    /// test above: the pair pins both sides of the `== nil` predicate so the
    /// inversion mutant cannot survive.
    func testIsValidPosition_negativeTimestamp_returnsFalse() {
        let position = TrackPosition(track: tracks.tracks[0], timestamp: -5, tracks: tracks)
        XCTAssertFalse(sut.isValidPosition(position, in: toc),
                       "A negative timestamp must make the position invalid")
    }

    /// Invalid position (foreign track key) → false, through the bool shim.
    func testIsValidPosition_foreignKey_returnsFalse() throws {
        let foreign = try makeForeignKeyedTrack()
        let position = TrackPosition(track: foreign, timestamp: 10, tracks: tracks)
        XCTAssertFalse(sut.isValidPosition(position, in: toc),
                       "A track key absent from the manifest must make the position invalid")
    }

    // MARK: - selectMostRecentValidBookmark — recency ordering (line ~1305)

    /// Three valid bookmarks at distinct tracks with strictly increasing
    /// ISO8601 `lastSavedTimeStamp`s. The selection must return the
    /// most-recent one (track index 2, the newest stamp).
    ///
    /// This kills BOTH sort mutants on `candidates.sorted { $0.1 > $1.1 }`:
    ///   - `>` → `<` (reverse sort) would return the OLDEST bookmark
    ///     (track 0) — assertion on track index 2 fails.
    ///   - `>` → `>=` (tie-break flip) is covered by the distinct-stamp
    ///     ordering plus the tie test below.
    func testSelectMostRecentValidBookmark_picksNewestByTimestamp() {
        let locations = [
            makeBookmarkLocation(track: tracks.tracks[0], timestamp: 10, savedAt: "2026-01-01T00:00:00Z"),
            makeBookmarkLocation(track: tracks.tracks[2], timestamp: 30, savedAt: "2026-03-01T00:00:00Z"),
            makeBookmarkLocation(track: tracks.tracks[1], timestamp: 20, savedAt: "2026-02-01T00:00:00Z"),
        ]

        let selected = sut.selectMostRecentValidBookmark(from: locations, in: toc)

        XCTAssertNotNil(selected, "Three valid bookmarks must yield a selection")
        XCTAssertEqual(selected?.track.key, tracks.tracks[2].key,
                       "Must select the newest bookmark (2026-03 → track index 2). A reverse sort would pick track 0; a wrong tie-break would not pick this one deterministically.")
    }

    /// The newest bookmark wins even when the array is supplied OLDEST-first,
    /// so the result reflects timestamp ordering, not array order. A reverse
    /// sort would return the first (oldest) element instead.
    func testSelectMostRecentValidBookmark_ignoresArrayOrder_usesTimestamp() {
        let locations = [
            makeBookmarkLocation(track: tracks.tracks[0], timestamp: 10, savedAt: "2025-01-01T00:00:00Z"),
            makeBookmarkLocation(track: tracks.tracks[1], timestamp: 20, savedAt: "2027-12-31T23:59:59Z"),
        ]

        let selected = sut.selectMostRecentValidBookmark(from: locations, in: toc)
        XCTAssertEqual(selected?.track.key, tracks.tracks[1].key,
                       "Newest (2027) must win regardless of position in the input array")
    }

    // MARK: - selectMostRecentValidBookmark — validation filter (line ~1297)

    /// Mix of valid and invalid bookmarks where BOTH reconstruct successfully
    /// (in-manifest track keys) so the discriminator is the
    /// `validationFailure(...) == nil` FILTER, not the upstream
    /// `TrackPosition(audioBookmark:)` reconstruction guard. The invalid one
    /// has the NEWEST timestamp but a position past the duration cap
    /// (`.positionExceedsCap`), so the filter must drop it and the older VALID
    /// bookmark is selected.
    ///
    /// Kills the `== nil` → `!= nil` mutant on the in-filter
    /// `validationFailure(...) == nil`: under the mutant the filter inverts —
    /// it KEEPS the cap-exceeding candidate and DROPS the valid one — so the
    /// newest-but-invalid bookmark would be selected and this assertion flips.
    func testSelectMostRecentValidBookmark_dropsCapExceedingCandidate_keepsValidOlder() {
        // Position far past the end of the book on the last track → durationToSelf
        // exceeds totalDuration * 1.1 → .positionExceedsCap. Key is valid, so it
        // reconstructs and reaches the validationFailure filter.
        let lastTrack = tracks.tracks[tracks.tracks.count - 1]
        let capExceedingNewer = makeBookmarkLocation(
            track: lastTrack,
            timestamp: 10_000_000,   // ~115 days into a single track — way past the cap
            savedAt: "2099-01-01T00:00:00Z"
        )
        let validOlder = makeBookmarkLocation(
            track: tracks.tracks[0],
            timestamp: 10,
            savedAt: "2026-01-01T00:00:00Z"
        )

        let selected = sut.selectMostRecentValidBookmark(
            from: [capExceedingNewer, validOlder],
            in: toc
        )

        XCTAssertNotNil(selected,
                        "One valid candidate remains after filtering → must select it")
        XCTAssertEqual(selected?.track.key, tracks.tracks[0].key,
                       "The newest candidate exceeds the duration cap and MUST be filtered out by validationFailure; the valid (older) bookmark is selected. A filter inversion would keep the cap-exceeding one.")
        XCTAssertEqual(selected?.timestamp, 10,
                       "Selected position must be the valid older bookmark's offset, not the cap-exceeding one")
    }

    /// When EVERY candidate fails validation (here: position past the duration
    /// cap, valid key so it reconstructs and reaches the filter), the filter
    /// removes all of them and selection returns nil. Exercises the
    /// `validationFailure == nil` filter on the all-fail path.
    func testSelectMostRecentValidBookmark_allFailValidation_returnsNil() {
        let lastTrack = tracks.tracks[tracks.tracks.count - 1]
        let capExceeding = makeBookmarkLocation(
            track: lastTrack,
            timestamp: 10_000_000,
            savedAt: "2026-05-05T00:00:00Z"
        )

        let selected = sut.selectMostRecentValidBookmark(from: [capExceeding], in: toc)
        XCTAssertNil(selected,
                     "Only candidate exceeds the duration cap → filtered out → no fallback position")
    }

    // MARK: - isUserAuthenticated — auth-doc load failure (return false, line ~1517)

    /// When the current account's auth-document load has FAILED
    /// (`.detailsFailed`), `awaitReady()` throws and the manager must surface
    /// the patron as not-authenticated (→ `.notAuthenticated` open error).
    /// Pins the `catch { return false }` branch: the `return false` → `return
    /// true` mutant would report the patron authenticated despite an auth-doc
    /// load failure, opening the book against a stale/absent auth surface.
    func testIsUserAuthenticated_authDocLoadFailed_returnsFalse() async {
        let manager = makeIsolatedAccountsManager()
        let account = makeAccount(uuid: "pp4542-failed-auth")
        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "HTTP 503")))
        manager.currentAccount = account

        let container = makeTestAppContainer(accountsManager: manager, bookRegistry: registryMock)
        let sutWithFailedAuth = AudiobookSessionManager(appContainer: container)

        let authed = await sutWithFailedAuth.isUserAuthenticated()
        XCTAssertFalse(authed,
                       "A failed auth-document load must surface as not-authenticated (the open path maps this to .notAuthenticated)")

        manager.cancelBackgroundWork()
    }

    /// Control case: when there is no current account at all, the patron is
    /// likewise not authenticated. Together with the failure test above this
    /// pins that the not-authenticated outcome is reached on both early-out
    /// `return false` paths in the method.
    func testIsUserAuthenticated_noCurrentAccount_returnsFalse() async {
        let manager = makeIsolatedAccountsManager()
        manager.currentAccount = nil

        let container = makeTestAppContainer(accountsManager: manager, bookRegistry: registryMock)
        let sutNoAccount = AudiobookSessionManager(appContainer: container)

        let authed = await sutNoAccount.isUserAuthenticated()
        XCTAssertFalse(authed, "No current account → not authenticated")

        manager.cancelBackgroundWork()
    }

    // MARK: - Account / manager fixtures

    private func makeIsolatedAccountsManager() -> AccountsManager {
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        return AccountsManager()
    }

    private func makeAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "pp4542 test library",
            id: uuid,
            title: "PP-4542 Test Library"
        )
        let pub = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: pub, imageCache: MockImageCache())
    }
}
