//
//  AudiobookPositionTraceTests.swift
//  PalaceTests
//
//  PP-4963 — the instrumentation that decides whether position saves stop
//  during long locked background playback.
//
//  Both policies are pure functions over a finite input space, so these are
//  written as TRANSITION TABLES rather than scenarios: every reachable cell
//  gets a cell, including the threshold boundaries where an off-by-one would
//  silently reclassify the defect as healthy.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class PositionSaveDryPolicyTests: XCTestCase {

    /// Fixed clock. Every case is expressed as an offset from this so a cell
    /// reads as its position in the table, not as arithmetic.
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let threshold: TimeInterval = 120
    private let freshness: TimeInterval = 10

    private func evaluate(
        sessionAge: TimeInterval,
        lastTickAge: TimeInterval?,
        lastSaveAge: TimeInterval?
    ) -> PositionSaveVerdict {
        PositionSaveDryPolicy.evaluate(
            now: now,
            sessionStartedAt: now.addingTimeInterval(-sessionAge),
            lastTickAt: lastTickAge.map { now.addingTimeInterval(-$0) },
            lastSaveAt: lastSaveAge.map { now.addingTimeInterval(-$0) },
            dryThreshold: threshold,
            tickFreshness: freshness
        )
    }

    // MARK: - No playback signal at all

    /// The instrument must be able to report that it learned nothing. If a
    /// missing liveness signal collapsed into `.dry`, an inert recorder would
    /// manufacture the exact finding the ticket is looking for.
    func testNoTicks_withNoSaves_reportsNoPlayback_notDry() {
        XCTAssertEqual(
            evaluate(sessionAge: 3600, lastTickAge: nil, lastSaveAge: nil),
            .noPlayback
        )
    }

    func testNoTicks_withRecentSave_reportsNoPlayback() {
        XCTAssertEqual(
            evaluate(sessionAge: 3600, lastTickAge: nil, lastSaveAge: 1),
            .noPlayback
        )
    }

    // MARK: - Playback stopped before the check

    /// Audio that stopped an hour ago explains a dry save window by itself.
    /// Reporting `.dry` here would flood the fleet with every paused session.
    func testStaleTicks_withAncientSave_reportsPlaybackStale() {
        guard case let .playbackStale(sinceLastTick) =
                evaluate(sessionAge: 7200, lastTickAge: 3600, lastSaveAge: 3600) else {
            return XCTFail("expected .playbackStale")
        }
        XCTAssertEqual(sinceLastTick, 3600, accuracy: 0.001)
    }

    func testTickExactlyAtFreshnessBoundary_countsAsLive_notStale() {
        // `> freshness` is stale; exactly AT the boundary is still live.
        let verdict = evaluate(sessionAge: 7200, lastTickAge: freshness, lastSaveAge: 3600)
        XCTAssertNotEqual(verdict, .noPlayback)
        guard case .dry = verdict else {
            return XCTFail("a tick exactly at the freshness boundary is live, so a 1h-old save is dry; got \(verdict)")
        }
    }

    func testTickJustPastFreshnessBoundary_isStale() {
        guard case .playbackStale = evaluate(
            sessionAge: 7200,
            lastTickAge: freshness + 0.001,
            lastSaveAge: 3600
        ) else {
            return XCTFail("expected .playbackStale just past the boundary")
        }
    }

    // MARK: - The defect: playback live, saves quiet

    func testLiveTicks_withSaveOlderThanThreshold_reportsDry() {
        guard case let .dry(seconds) =
                evaluate(sessionAge: 10_900, lastTickAge: 0.25, lastSaveAge: 10_800) else {
            return XCTFail("expected .dry")
        }
        XCTAssertEqual(seconds, 10_800, accuracy: 0.001,
                       "the reported duration is the patron-visible loss window")
    }

    /// A session that has been playing longer than the threshold and has NEVER
    /// saved is the worst case, not an exempt one. Falling back to session
    /// start keeps a never-saved session from reading as healthy.
    func testLiveTicks_withNoSaveEver_andOldSession_reportsDry() {
        guard case let .dry(seconds) =
                evaluate(sessionAge: 600, lastTickAge: 0.25, lastSaveAge: nil) else {
            return XCTFail("expected .dry for a long session that never saved")
        }
        XCTAssertEqual(seconds, 600, accuracy: 0.001)
    }

    func testLiveTicks_withNoSaveEver_butYoungSession_reportsSaving() {
        guard case .saving = evaluate(sessionAge: 5, lastTickAge: 0.25, lastSaveAge: nil) else {
            return XCTFail("a 5s-old session has not had time to save yet")
        }
    }

    // MARK: - Healthy cadence

    func testLiveTicks_withRecentSave_reportsSaving() {
        guard case let .saving(sinceLastSave) =
                evaluate(sessionAge: 3600, lastTickAge: 0.25, lastSaveAge: 5) else {
            return XCTFail("expected .saving")
        }
        XCTAssertEqual(sinceLastSave, 5, accuracy: 0.001)
    }

    func testSaveExactlyAtDryThreshold_isNotYetDry() {
        // `> threshold` is dry; exactly AT the threshold is still saving.
        guard case .saving = evaluate(sessionAge: 3600, lastTickAge: 0.25, lastSaveAge: threshold) else {
            return XCTFail("exactly at the threshold must not be dry")
        }
    }

    func testSaveJustPastDryThreshold_isDry() {
        guard case .dry = evaluate(
            sessionAge: 3600,
            lastTickAge: 0.25,
            lastSaveAge: threshold + 0.001
        ) else {
            return XCTFail("just past the threshold must be dry")
        }
    }

    /// Wall-clock can step backwards (NTP, timezone, manual set). A save that
    /// appears to be in the future must not read as an enormous dry window.
    func testSaveTimestampInTheFuture_reportsSaving_notDry() {
        guard case .saving = evaluate(sessionAge: 3600, lastTickAge: 0.25, lastSaveAge: -50) else {
            return XCTFail("a future-dated save is clock skew, not a 50s dry window")
        }
    }
}

final class PositionRestoreGapPolicyTests: XCTestCase {

    private let tolerance: Double = 10

    /// A two-track book: track "a" is 600s long and starts at absolute 0,
    /// track "b" starts at absolute 600. Anything else is absent from the
    /// manifest, which is the 3.2.3 Cause 2 shape.
    private func offset(_ trackKey: String, _ timestamp: Double) -> Double? {
        switch trackKey {
        case "a": return timestamp
        case "b": return 600 + timestamp
        default: return nil
        }
    }

    private func marker(
        bookID: String = "book-1",
        trackKey: String = "a",
        timestamp: Double = 0
    ) -> LastLivePositionMarker {
        LastLivePositionMarker(
            bookID: bookID,
            trackKey: trackKey,
            timestamp: timestamp,
            recordedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private func evaluate(
        marker: LastLivePositionMarker?,
        bookID: String = "book-1",
        restoredTrackKey: String = "a",
        restoredTimestamp: Double = 0,
        tolerance: Double? = nil
    ) -> PositionRestoreGapVerdict {
        PositionRestoreGapPolicy.evaluate(
            marker: marker,
            bookID: bookID,
            restoredTrackKey: restoredTrackKey,
            restoredTimestamp: restoredTimestamp,
            absoluteOffset: offset,
            tolerance: tolerance ?? self.tolerance
        )
    }

    // MARK: - Nothing to compare against

    func testNoMarker_reportsNoMarker() {
        XCTAssertEqual(evaluate(marker: nil), .noMarker)
    }

    func testMarkerFromAnotherBook_isNotCompared() {
        XCTAssertEqual(
            evaluate(marker: marker(bookID: "book-2"), bookID: "book-1"),
            .markerForDifferentBook
        )
    }

    // MARK: - Unresolvable against the loaded manifest

    /// A marker naming a track the manifest does not contain cannot be
    /// compared. It must NOT fall through to `.aligned` — silently treating an
    /// unresolvable position as agreement is exactly the 3.2.3 Cause 2 defect,
    /// and here it would report a healthy restore for a book that lost its place.
    func testMarkerTrackAbsentFromManifest_reportsUnresolvable_notAligned() {
        XCTAssertEqual(
            evaluate(marker: marker(trackKey: "ghost", timestamp: 12)),
            .markerUnresolvable(trackKey: "ghost")
        )
    }

    func testRestoredTrackAbsentFromManifest_reportsUnresolvable() {
        XCTAssertEqual(
            evaluate(marker: marker(trackKey: "a", timestamp: 12), restoredTrackKey: "ghost"),
            .markerUnresolvable(trackKey: "ghost")
        )
    }

    // MARK: - Agreement

    func testExactMatch_reportsAligned() {
        guard case let .aligned(drift) = evaluate(
            marker: marker(trackKey: "a", timestamp: 100),
            restoredTrackKey: "a",
            restoredTimestamp: 100
        ) else {
            return XCTFail("expected .aligned")
        }
        XCTAssertEqual(drift, 0, accuracy: 0.001)
    }

    func testGapExactlyAtTolerance_reportsAligned() {
        guard case .aligned = evaluate(
            marker: marker(trackKey: "a", timestamp: 110),
            restoredTrackKey: "a",
            restoredTimestamp: 100
        ) else {
            return XCTFail("a gap exactly at tolerance is still aligned")
        }
    }

    /// A negative tolerance would make `.aligned` unreachable and admit a gap
    /// of exactly zero into the behind/ahead sign test, where zero has no
    /// correct answer. The band is clamped at zero so that cannot be expressed:
    /// an exact match stays aligned however the caller sets the tolerance.
    func testNegativeTolerance_isClampedToZero_soExactMatchStaysAligned() {
        guard case let .aligned(drift) = evaluate(
            marker: marker(trackKey: "a", timestamp: 100),
            restoredTrackKey: "a",
            restoredTimestamp: 100,
            tolerance: -5
        ) else {
            return XCTFail("a negative tolerance must not push an exact match into behind/ahead")
        }
        XCTAssertEqual(drift, 0, accuracy: 0.001)
    }

    func testZeroTolerance_classifiesAnyNonZeroGap() {
        guard case let .behind(seconds) = evaluate(
            marker: marker(trackKey: "a", timestamp: 100.5),
            restoredTrackKey: "a",
            restoredTimestamp: 100,
            tolerance: 0
        ) else {
            return XCTFail("with no tolerance band, any positive gap is behind")
        }
        XCTAssertEqual(seconds, 0.5, accuracy: 0.001)
    }

    // MARK: - The patron's complaint

    func testRestoredEarlierThanLastLive_reportsBehind() {
        guard case let .behind(seconds) = evaluate(
            marker: marker(trackKey: "a", timestamp: 110.001),
            restoredTrackKey: "a",
            restoredTimestamp: 100
        ) else {
            return XCTFail("just past tolerance must be reported")
        }
        XCTAssertEqual(seconds, 10.001, accuracy: 0.001)
    }

    /// The shape patrons describe — "came back three hours behind" — spanning
    /// a track boundary, which is where naive same-track arithmetic breaks.
    func testRestoredHoursBehindAcrossTrackBoundary_reportsBehind() {
        guard case let .behind(seconds) = evaluate(
            marker: marker(trackKey: "b", timestamp: 3000),
            restoredTrackKey: "a",
            restoredTimestamp: 600
        ) else {
            return XCTFail("expected .behind across a track boundary")
        }
        // live = 600 + 3000 = 3600; restored = 600 → exactly one hour lost.
        XCTAssertEqual(seconds, 3000, accuracy: 0.001)
    }

    /// Restoring LATER than the last position we saw live is not the patron
    /// complaint, but it is a real signal (a stale remote winning over a newer
    /// local), so it gets its own verdict rather than being folded into
    /// `.behind` or dropped.
    func testRestoredLaterThanLastLive_reportsAhead() {
        guard case let .ahead(seconds) = evaluate(
            marker: marker(trackKey: "a", timestamp: 100),
            restoredTrackKey: "b",
            restoredTimestamp: 0
        ) else {
            return XCTFail("expected .ahead")
        }
        // live = 100; restored = 600 → 500s ahead.
        XCTAssertEqual(seconds, 500, accuracy: 0.001)
    }
}
