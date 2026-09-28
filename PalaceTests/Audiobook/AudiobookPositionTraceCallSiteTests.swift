//
//  AudiobookPositionTraceCallSiteTests.swift
//  PalaceTests
//
//  PP-4963 — the two production call sites that tell the trace a save
//  happened, and the store that persists the last-live marker.
//
//  Review caught that neither was pinned. The earlier severance test deleted
//  the call sites alongside three other joins, so the five failures it produced
//  all came from the others: deleting ONLY the two `positionTrace?.noteSave`
//  lines left every test green. That failure mode is the worst one available
//  here — `lastSaveAt` stays nil, so every healthy locked session reports
//  `.dry` on the ungated fleet signal, manufacturing the finding PP-4963 exists
//  to confirm.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel
@testable import PalaceAudiobookToolkit

final class AudiobookPositionTraceCallSiteTests: XCTestCase {

    private var tracks: Tracks!
    private var book: TPPBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        book = TPPBookMocker.snapshotAudiobook()
        let manifest = try Manifest.from(
            jsonFileName: ManifestJSON.snowcrash.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        tracks = Tracks(manifest: manifest, audiobookID: book.identifier, token: nil)
    }

    override func tearDownWithError() throws {
        tracks = nil
        book = nil
        try super.tearDownWithError()
    }

    /// Builds a recorder whose verdict is observable. The discriminator is the
    /// VERDICT, not a spy flag: a tick 200s in the past establishes
    /// `firstTickAt`, a fresh tick keeps playback live, and the save under test
    /// is the only thing that can move the reference forward. If the call site
    /// is missing, `lastSaveAt` stays nil, the policy falls back to
    /// `firstTickAt`, and 200s exceeds the 120s threshold — `.dry` instead of
    /// `.saving`. That is exactly the production failure this guards.
    private func makeRecorder(
        collecting verdicts: @escaping (PositionSaveVerdict) -> Void
    ) -> AudiobookPositionTraceRecorder {
        AudiobookPositionTraceRecorder(
            bookID: book.identifier,
            markerStore: RecordingMarkerStore(),
            diagnosticsEnabled: { true },
            reportSaveVerdict: { verdict, _ in verdicts(verdict) },
            fileLog: { _ in },
            emitFleetEvent: { _, _, _ in }
        )
    }

    /// A CONTINUOUS chain of ticks over the last 200 seconds, spaced closer
    /// together than the freshness window.
    ///
    /// Two ticks 200s apart would not do: `notePlaybackTick` resets
    /// `firstTickAt` when the gap exceeds `tickFreshnessWindow`, treating it as
    /// a resume. That reset made the first version of this test pass with the
    /// call sites deleted — the reference moved to the second tick and the
    /// verdict was `.saving` either way. Real playback ticks about four times a
    /// second, so a chain is also the honest shape.
    private func driveTicks(_ recorder: AudiobookPositionTraceRecorder, track: any Track) {
        let now = Date()
        for offset in stride(from: -200.0, through: 0.0, by: 5.0) {
            recorder.notePlaybackTick(
                trackKey: track.key,
                timestamp: 200 + offset,
                at: now.addingTimeInterval(offset)
            )
        }
    }

    /// The termination path. `saveListeningPositionSync` runs when iOS is about
    /// to kill the app — the one save a patron most depends on — and it must
    /// tell the trace, or a session that saved only at termination reports as
    /// never having saved at all.
    func testSaveListeningPositionSync_notifiesTheTrace() throws {
        var verdicts: [PositionSaveVerdict] = []
        let recorder = makeRecorder { verdicts.append($0) }
        let logic = AudiobookBookmarkBusinessLogic(
            book: book,
            registry: TPPBookRegistryMock(),
            annotationsManager: TPPAnnotationMock(),
            positionWriter: nil,
            positionTrace: recorder
        )
        let track = try XCTUnwrap(tracks.tracks.first)
        driveTicks(recorder, track: track)

        logic.saveListeningPositionSync(
            at: TrackPosition(track: track, timestamp: 120, tracks: tracks)
        )
        recorder.applicationDidBecomeActive()

        guard case .saving = verdicts.first else {
            return XCTFail(
                "the termination save must reach the trace — got \(verdicts), which "
                + "means lastSaveAt was never set and a saved session reads as dry"
            )
        }
    }

    /// The ordinary path. Every local position write must be reported, because
    /// a successful save leaves no other trace anywhere.
    func testSaveListeningPosition_notifiesTheTrace() throws {
        var verdicts: [PositionSaveVerdict] = []
        let recorder = makeRecorder { verdicts.append($0) }
        let logic = AudiobookBookmarkBusinessLogic(
            book: book,
            registry: TPPBookRegistryMock(),
            annotationsManager: TPPAnnotationMock(),
            positionWriter: nil,
            positionTrace: recorder
        )
        let track = try XCTUnwrap(tracks.tracks.first)
        driveTicks(recorder, track: track)

        let done = expectation(description: "save completes")
        logic.saveListeningPosition(
            at: TrackPosition(track: track, timestamp: 240, tracks: tracks)
        ) { _ in done.fulfill() }
        wait(for: [done], timeout: 5.0)

        recorder.applicationDidBecomeActive()

        guard case .saving = verdicts.first else {
            return XCTFail(
                "a local position write must reach the trace — got \(verdicts)"
            )
        }
    }
}

// MARK: - The marker store

final class UserDefaultsLastLivePositionMarkerStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "pp4963.marker.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    /// A Codable or key-prefix divergence would make the restore signal report
    /// `.noMarker` forever — and silence reads as health.
    func testMarkerRoundTrips() throws {
        let store = makeStore(diagnostics: true)
        let recorded = Date(timeIntervalSince1970: 1_000_000)
        store.save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "track-7", timestamp: 123.5, recordedAt: recorded
        ))

        let read = try XCTUnwrap(store.marker(forBookID: "book-1"))
        XCTAssertEqual(read.bookID, "book-1")
        XCTAssertEqual(read.trackKey, "track-7")
        XCTAssertEqual(read.timestamp, 123.5, accuracy: 0.001)
        XCTAssertEqual(read.recordedAt.timeIntervalSince1970,
                       recorded.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMarkersAreScopedPerBook() {
        let store = makeStore(diagnostics: true)
        store.save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 1, recordedAt: Date()
        ))

        XCTAssertNil(store.marker(forBookID: "book-2"),
                     "one book's marker is not another's evidence")
    }

    /// Switching the trace off must remove what it recorded — and nothing else.
    ///
    /// Asserted against the RAW defaults rather than through
    /// `marker(forBookID:)`. The read is gated on the same switch, and
    /// `DebugSettings` writes the switch false BEFORE calling `purgeAll`, so a
    /// read-based assertion would pass whether the purge ran or not — the exact
    /// order this test exists to cover.
    func testPurgeAll_removesMarkers_andLeavesOtherKeysAlone() {
        let store = makeStore(diagnostics: true)
        defaults.set("keep me", forKey: "unrelated.setting")
        defaults.set(true, forKey: "debug.audiobookPositionTrace")
        for id in ["book-1", "book-2", "book-3"] {
            store.save(LastLivePositionMarker(
                bookID: id, trackKey: "a", timestamp: 1, recordedAt: Date()
            ))
        }
        XCTAssertNotNil(rawMarkerData(forBookID: "book-2"), "precondition")

        store.purgeAll()

        for id in ["book-1", "book-2", "book-3"] {
            XCTAssertNil(rawMarkerData(forBookID: id),
                         "\(id)'s recorded position must not outlive the switch")
        }
        XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "keep me",
                       "the purge is scoped to the marker namespace")
        XCTAssertTrue(defaults.bool(forKey: "debug.audiobookPositionTrace"),
                      "and must not clear the flag it is reacting to")
    }

    /// The order `DebugSettings.isAudiobookPositionTraceEnabled` actually uses:
    /// the switch is written false first, and the purge runs after. A purge
    /// that consulted the switch would decline to delete exactly the markers it
    /// exists to remove, and every one of them would survive indefinitely.
    func testPurgeAll_withDiagnosticsAlreadyOff_stillRemovesMarkers() {
        makeStore(diagnostics: true).save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 1, recordedAt: Date()
        ))
        XCTAssertNotNil(rawMarkerData(forBookID: "book-1"), "precondition")

        makeStore(diagnostics: false).purgeAll()

        XCTAssertNil(
            rawMarkerData(forBookID: "book-1"),
            "the purge runs after the switch is off; gating it would strand every "
            + "marker a trace run recorded"
        )
    }

    // MARK: - The diagnostics gate

    /// A reading position is patron data, and this store keeps one outside
    /// `TPPBookRegistry`'s deletion lifecycle. With the switch off nothing may
    /// be written — asserted against the raw `UserDefaults` bytes, because the
    /// read is gated too and would report `nil` either way.
    func testMarkerStore_withDiagnosticsOff_writesNothingToUserDefaults() {
        makeStore(diagnostics: false).save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "track-7", timestamp: 123.5, recordedAt: Date()
        ))

        XCTAssertNil(
            rawMarkerData(forBookID: "book-1"),
            "a default build must persist no reading position; there is no purge "
            + "on return, delete, sign-out or account switch to undo it"
        )
    }

    /// The other half of the gate, and the one that is not merely tidiness: a
    /// blob left behind by an earlier diagnostics-on run must not be read back
    /// by a build that is recording nothing.
    func testMarkerStore_withDiagnosticsOff_doesNotReadAnExistingMarker() {
        makeStore(diagnostics: true).save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "track-7", timestamp: 123.5, recordedAt: Date()
        ))
        XCTAssertNotNil(rawMarkerData(forBookID: "book-1"), "precondition: it is on disk")

        XCTAssertNil(
            makeStore(diagnostics: false).marker(forBookID: "book-1"),
            "with the switch off the store must not surface a position an earlier "
            + "run recorded"
        )
    }

    /// The consequence at the verdict: with the switch off the restore-gap arm
    /// degrades to `.noMarker` rather than reporting a gap out of stale bytes.
    func testRestoreGap_withDiagnosticsOff_degradesToNoMarker() {
        makeStore(diagnostics: true).save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 10_800, recordedAt: Date()
        ))
        var reported: [PositionRestoreGapVerdict] = []
        let recorder = AudiobookPositionTraceRecorder(
            bookID: "book-1",
            markerStore: makeStore(diagnostics: false),
            diagnosticsEnabled: { false },
            reportGapVerdict: { reported.append($0) },
            fileLog: { _ in }
        )

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a", restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        XCTAssertEqual(
            reported, [.noMarker],
            "a build that records nothing must report nothing; reading the stale "
            + "blob here would emit code 405 from a session it never observed"
        )
    }

    /// Non-vacuity for the two above: the same shapes with the switch open must
    /// round-trip and must produce the gap.
    func testRestoreGap_withDiagnosticsOn_reportsTheGapFromTheSameStore() {
        makeStore(diagnostics: true).save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 10_800, recordedAt: Date()
        ))
        var reported: [PositionRestoreGapVerdict] = []
        let recorder = AudiobookPositionTraceRecorder(
            bookID: "book-1",
            markerStore: makeStore(diagnostics: true),
            diagnosticsEnabled: { true },
            reportGapVerdict: { reported.append($0) },
            fileLog: { _ in }
        )

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a", restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        XCTAssertEqual(reported, [.behind(seconds: 10_800)])
    }

    // MARK: - The defaults nothing was taking

    // Every other test in this file, and every other construction of either
    // type in the suite, injects `diagnosticsEnabled` explicitly. That is good
    // isolation and it left the DEFAULT bindings — the only ones production
    // takes — exercised by nothing. `AudiobookLoader.makePositionTrace` builds
    // `AudiobookPositionTraceRecorder(bookID:)` and accepts all of them.
    //
    // Measured before these two existed: replacing the store's default closure
    // body with `false` left 142/142 green, and so did replacing the recorder's.
    // Gutted, the trace reads and writes nothing and codes 404-407 go
    // permanently silent — which, by this feature's own thesis, is
    // indistinguishable from a healthy fleet.

    /// The store's default gate reads the switch, in the store's OWN domain.
    ///
    /// Three mutations die here: the default closure returning a constant, the
    /// closure reading `DebugSettings()` instead of `DebugSettings(defaults:)`,
    /// and the captured `gateDefaults` being repointed at `.standard` — all
    /// three leave the scoped domain empty.
    func testStoreDefaultGate_readsTheSwitchInItsOwnDomain() {
        DebugSettings(defaults: defaults).isAudiobookPositionTraceEnabled = true
        // No `diagnosticsEnabled:` — this is the production binding.
        let store = UserDefaultsLastLivePositionMarkerStore(defaults: defaults)

        store.save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 42, recordedAt: Date()
        ))

        XCTAssertNotNil(rawMarkerData(forBookID: "book-1"),
                        "with the switch open in this domain, the default gate "
                        + "must let the write through")
    }

    /// And declines with the switch closed.
    ///
    /// A fresh store on a domain where the flag was never set — not the same
    /// store after writing `false`. Writing `false` through `DebugSettings`
    /// also calls `purgeAll`, so an absence afterwards would be evidence of the
    /// purge, not of the gate. This asserts the gate.
    func testStoreDefaultGate_declinesWithTheSwitchClosed() {
        XCTAssertFalse(DebugSettings(defaults: defaults).isAudiobookPositionTraceEnabled,
                       "precondition: the flag is unset in this domain")
        let store = UserDefaultsLastLivePositionMarkerStore(defaults: defaults)

        store.save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 42, recordedAt: Date()
        ))

        XCTAssertNil(rawMarkerData(forBookID: "book-1"),
                     "a patron's position must not be persisted while the "
                     + "trace is off")
    }

    /// The recorder's own default gate and default store, driven end to end.
    ///
    /// `notePlaybackTick` is the production write path, and `lastMarkerWriteAt`
    /// starts at `.distantPast`, so the first tick writes. The bytes are read
    /// raw from the injected domain, which is what makes this fail if either
    /// default reaches `.standard` instead.
    func testRecorderDefaults_gateAndStore_bothBindToTheInjectedDomain() {
        DebugSettings(defaults: defaults).isAudiobookPositionTraceEnabled = true
        // Only `bookID` and `defaults`: `markerStore` and `diagnosticsEnabled`
        // are the bindings under test.
        let recorder = AudiobookPositionTraceRecorder(
            bookID: "book-1", defaults: defaults, fileLog: { _ in }
        )

        recorder.notePlaybackTick(trackKey: "a", timestamp: 12.5, at: Date())

        let data = rawMarkerData(forBookID: "book-1")
        XCTAssertNotNil(data,
                        "the recorder's default store and default gate must "
                        + "both resolve to the domain it was given")
    }

    /// Non-vacuity for the above: the same construction with the switch closed
    /// writes nothing, so the assertion is reading the gate and not merely the
    /// fact that a tick happened.
    func testRecorderDefaults_writeNothingWhileTheSwitchIsClosed() {
        XCTAssertFalse(DebugSettings(defaults: defaults).isAudiobookPositionTraceEnabled,
                       "precondition: the flag is unset in this domain")
        let recorder = AudiobookPositionTraceRecorder(
            bookID: "book-1", defaults: defaults, fileLog: { _ in }
        )

        recorder.notePlaybackTick(trackKey: "a", timestamp: 12.5, at: Date())

        XCTAssertNil(rawMarkerData(forBookID: "book-1"))
    }

    // MARK: - Helpers

    private func makeStore(diagnostics: Bool) -> UserDefaultsLastLivePositionMarkerStore {
        UserDefaultsLastLivePositionMarkerStore(
            defaults: defaults,
            diagnosticsEnabled: { diagnostics }
        )
    }

    /// Reads the stored bytes directly, bypassing the gated accessor.
    private func rawMarkerData(forBookID bookID: String) -> Data? {
        defaults.data(forKey: "audiobook.lastLivePosition." + bookID)
    }
}

/// Marker store that also records whether anything was written, for the
/// call-site tests.
private final class RecordingMarkerStore: LastLivePositionMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var markers: [String: LastLivePositionMarker] = [:]

    func marker(forBookID bookID: String) -> LastLivePositionMarker? {
        lock.lock(); defer { lock.unlock() }
        return markers[bookID]
    }

    func save(_ marker: LastLivePositionMarker) {
        lock.lock(); defer { lock.unlock() }
        markers[marker.bookID] = marker
    }
}
