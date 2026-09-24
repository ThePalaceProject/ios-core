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
        let store = UserDefaultsLastLivePositionMarkerStore(defaults: defaults)
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
        let store = UserDefaultsLastLivePositionMarkerStore(defaults: defaults)
        store.save(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 1, recordedAt: Date()
        ))

        XCTAssertNil(store.marker(forBookID: "book-2"),
                     "one book's marker is not another's evidence")
    }

    /// Switching the trace off must remove what it recorded — and nothing else.
    func testPurgeAll_removesMarkers_andLeavesOtherKeysAlone() {
        let store = UserDefaultsLastLivePositionMarkerStore(defaults: defaults)
        defaults.set("keep me", forKey: "unrelated.setting")
        defaults.set(true, forKey: "debug.audiobookPositionTrace")
        for id in ["book-1", "book-2", "book-3"] {
            store.save(LastLivePositionMarker(
                bookID: id, trackKey: "a", timestamp: 1, recordedAt: Date()
            ))
        }
        XCTAssertNotNil(store.marker(forBookID: "book-2"), "precondition")

        store.purgeAll()

        for id in ["book-1", "book-2", "book-3"] {
            XCTAssertNil(store.marker(forBookID: id),
                         "\(id)'s recorded position must not outlive the switch")
        }
        XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "keep me",
                       "the purge is scoped to the marker namespace")
        XCTAssertTrue(defaults.bool(forKey: "debug.audiobookPositionTrace"),
                      "and must not clear the flag it is reacting to")
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
