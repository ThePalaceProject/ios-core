//
//  AudiobookPositionTraceRecorderTests.swift
//  PalaceTests
//
//  PP-4963 — orchestration around the two pure policies. The decisions live in
//  `PositionSaveDryPolicy` / `PositionRestoreGapPolicy` and are tabled in
//  `AudiobookPositionTraceTests`; what is pinned here is the wiring that makes
//  those decisions mean anything — chiefly that the instrument cannot agree
//  with itself.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

private final class SpyMarkerStore: LastLivePositionMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var markers: [String: LastLivePositionMarker] = [:]
    private(set) var writeCount = 0

    func marker(forBookID bookID: String) -> LastLivePositionMarker? {
        lock.lock(); defer { lock.unlock() }
        return markers[bookID]
    }

    func save(_ marker: LastLivePositionMarker) {
        lock.lock(); defer { lock.unlock() }
        markers[marker.bookID] = marker
        writeCount += 1
    }

    func seed(_ marker: LastLivePositionMarker) {
        lock.lock(); defer { lock.unlock() }
        markers[marker.bookID] = marker
    }
}

final class AudiobookPositionTraceRecorderTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var store: SpyMarkerStore!
    private var reported: [PositionSaveVerdict] = []
    private var gapsReported: [PositionRestoreGapVerdict] = []

    private func makeRecorder(diagnosticsEnabled: Bool = true) -> AudiobookPositionTraceRecorder {
        store = SpyMarkerStore()
        reported = []
        gapsReported = []
        return AudiobookPositionTraceRecorder(
            bookID: "book-1",
            markerStore: store,
            diagnosticsEnabled: { diagnosticsEnabled },
            reportSaveVerdict: { [weak self] in self?.reported.append($0) },
            reportGapVerdict: { [weak self] in self?.gapsReported.append($0) },
            now: { [weak self] in self?.clock ?? Date() }
        )
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    // MARK: - The instrument must not agree with itself

    /// The whole measurement turns on this. If a position save also refreshed
    /// the last-live marker, the restore gap would be the difference between a
    /// value and itself — identically zero — and a book that lost three hours
    /// would report a perfect restore. Saves record only that a save happened.
    func testNoteSave_doesNotWriteTheLastLiveMarker() {
        let recorder = makeRecorder()
        recorder.noteSave(at: clock)
        advance(300)
        recorder.noteSave(at: clock)

        XCTAssertEqual(store.writeCount, 0,
                       "a save must never advance the marker it is measured against")
        XCTAssertNil(store.marker(forBookID: "book-1"))
    }

    /// The marker advances on the playback clock, which is the signal that
    /// keeps running while the screen is locked.
    func testPlaybackTick_writesTheMarker_onItsOwnCadence() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 10, at: clock)
        XCTAssertEqual(store.writeCount, 1, "the first tick establishes the marker")

        // Ticks arrive ~4x/second; the marker must not be rewritten that often.
        advance(1)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 11, at: clock)
        XCTAssertEqual(store.writeCount, 1, "a tick inside the write interval is absorbed")

        advance(AudiobookPositionTraceRecorder.markerWriteInterval)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 71, at: clock)
        XCTAssertEqual(store.writeCount, 2, "a tick past the interval advances the marker")

        let marker = store.marker(forBookID: "book-1")
        XCTAssertEqual(marker?.trackKey, "a")
        XCTAssertEqual(marker?.timestamp ?? 0, 71, accuracy: 0.001)
    }

    /// Pins the cadence comparison EXACTLY on the boundary. The test above
    /// advances past it in two steps, so it cannot distinguish `>=` from `>` —
    /// a tick landing precisely on the interval has to be the one asserted, or
    /// an off-by-one in the write condition goes unnoticed and the marker
    /// silently records at a different rate than the trace claims.
    func testPlaybackTick_exactlyOnTheWriteInterval_advancesTheMarker() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)
        XCTAssertEqual(store.writeCount, 1)

        advance(AudiobookPositionTraceRecorder.markerWriteInterval)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 60, at: clock)

        XCTAssertEqual(store.writeCount, 2,
                       "a tick exactly at the interval must write; the comparison is >=, not >")
    }

    func testPlaybackTick_justInsideTheWriteInterval_doesNotAdvanceTheMarker() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)

        advance(AudiobookPositionTraceRecorder.markerWriteInterval - 0.001)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 60, at: clock)

        XCTAssertEqual(store.writeCount, 1, "a tick just short of the interval is absorbed")
    }

    // MARK: - Foreground verdict

    func testForegroundReturn_afterLivePlaybackWithNoSaves_reportsDry() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)
        recorder.noteSave(at: clock)

        // Three hours of locked listening: the playback clock keeps ticking,
        // the save path goes quiet.
        advance(10_800)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 10_800, at: clock)

        recorder.applicationDidBecomeActive()

        guard case let .dry(seconds)? = reported.first else {
            return XCTFail("expected a dry verdict, got \(reported)")
        }
        XCTAssertEqual(seconds, 10_800, accuracy: 1)
    }

    func testForegroundReturn_withSavesKeepingPace_reportsNothingToCrashlytics() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)
        advance(10)
        recorder.noteSave(at: clock)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 10, at: clock)

        recorder.applicationDidBecomeActive()

        XCTAssertTrue(
            reported.allSatisfy { if case .dry = $0 { return false } else { return true } },
            "a healthy session must not emit a dry finding: \(reported)"
        )
    }

    /// A recorder that never saw the playback clock has learned nothing, and
    /// must say so rather than emit the finding the ticket is hoping for.
    func testForegroundReturn_withNoPlaybackEver_doesNotReportDry() {
        let recorder = makeRecorder()
        advance(10_800)

        recorder.applicationDidBecomeActive()

        XCTAssertFalse(
            reported.contains { if case .dry = $0 { return true } else { return false } },
            "an inert recorder must not manufacture a dry finding: \(reported)"
        )
    }

    // MARK: - Restore gap

    func testRestoreGap_againstAMarkerHoursAhead_reportsBehind() {
        let recorder = makeRecorder()
        store.seed(LastLivePositionMarker(
            bookID: "book-1",
            trackKey: "a",
            timestamp: 10_800,
            recordedAt: clock
        ))

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a",
            restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        guard case let .behind(seconds)? = gapsReported.first else {
            return XCTFail("expected .behind, got \(gapsReported)")
        }
        XCTAssertEqual(seconds, 10_800, accuracy: 0.001)
    }

    func testRestoreGap_withNoMarker_reportsNoMarker() {
        let recorder = makeRecorder()

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a",
            restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        XCTAssertEqual(gapsReported.first, .noMarker)
    }

    // MARK: - Session identity

    /// The recorder is per-book. A marker belonging to a different book must
    /// not be compared against this one's restore.
    func testRestoreGap_ignoresAMarkerFromAnotherBook() {
        let recorder = makeRecorder()
        store.seed(LastLivePositionMarker(
            bookID: "some-other-book",
            trackKey: "a",
            timestamp: 10_800,
            recordedAt: clock
        ))

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a",
            restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        XCTAssertEqual(gapsReported.first, .noMarker,
                       "another book's marker is not this book's evidence")
    }
}
