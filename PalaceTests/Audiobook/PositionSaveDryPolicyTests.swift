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

    /// Fixed clock. Every case is an offset from this so a cell reads as its
    /// position in the table, not as arithmetic.
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let threshold: TimeInterval = 120
    private let freshness: TimeInterval = 10

    private func evaluate(
        startedAgo: TimeInterval? = nil,
        lastTickAgo: TimeInterval? = nil,
        lastSaveAgo: TimeInterval? = nil,
        precededByGap: TimeInterval? = nil
    ) -> PositionSaveVerdict {
        let stretch = startedAgo.map { started in
            PlaybackStretch(
                startedAt: now.addingTimeInterval(-started),
                lastTickAt: now.addingTimeInterval(-(lastTickAgo ?? started)),
                lastSaveAt: lastSaveAgo.map { now.addingTimeInterval(-$0) },
                precededByGap: precededByGap
            )
        }
        return PositionSaveDryPolicy.evaluate(
            now: now, stretch: stretch,
            dryThreshold: threshold, tickFreshness: freshness
        )
    }

    // MARK: - Cell 1 — no stretch

    /// The instrument must be able to report that it learned nothing. If a
    /// missing liveness signal collapsed into `.dry`, an inert recorder would
    /// manufacture the exact finding the ticket is looking for.
    func testNoStretch_reportsNoPlayback_notDry() {
        XCTAssertEqual(evaluate(), .noPlayback)
    }

    // MARK: - Cell 2 — stretch present, ticks stale

    func testStaleTicks_reportPlaybackStale() {
        guard case let .playbackStale(since) =
                evaluate(startedAgo: 7200, lastTickAgo: 3600, lastSaveAgo: 3600) else {
            return XCTFail("expected .playbackStale")
        }
        XCTAssertEqual(since, 3600, accuracy: 0.001)
    }

    func testTickExactlyAtFreshnessBoundary_countsAsLive() {
        guard case .dry = evaluate(startedAgo: 7200, lastTickAgo: freshness, lastSaveAgo: 3600) else {
            return XCTFail("a tick exactly at the boundary is live, so an old save is dry")
        }
    }

    func testTickJustPastFreshnessBoundary_isStale() {
        guard case .playbackStale = evaluate(
            startedAgo: 7200, lastTickAgo: freshness + 0.001, lastSaveAgo: 3600
        ) else { return XCTFail("expected .playbackStale just past the boundary") }
    }

    // MARK: - Cell 3 — live, quiet window within threshold

    func testRecentSave_reportsSaving() {
        guard case let .saving(since) =
                evaluate(startedAgo: 3600, lastTickAgo: 0.25, lastSaveAgo: 5) else {
            return XCTFail("expected .saving")
        }
        XCTAssertEqual(since, 5, accuracy: 0.001)
    }

    func testSaveExactlyAtDryThreshold_isNotYetDry() {
        guard case .saving = evaluate(startedAgo: 3600, lastTickAgo: 0.25, lastSaveAgo: threshold) else {
            return XCTFail("exactly at the threshold must not be dry")
        }
    }

    /// A young stretch that has not saved yet is measured from its own start,
    /// so opening a book and glancing at it is not a finding.
    func testYoungStretchWithNoSave_reportsSaving() {
        guard case let .saving(since) = evaluate(startedAgo: 5, lastTickAgo: 0.25) else {
            return XCTFail("a 5s-old stretch has not had time to save")
        }
        XCTAssertEqual(since, 5, accuracy: 0.001)
    }

    /// Wall-clock can step backwards. A save that appears to be in the future
    /// must not read as a huge dry window, and the clamp is asserted by VALUE —
    /// `palace_mutate` has no operator for `max()`.
    func testFutureDatedSave_reportsSaving_clampedToZero() {
        guard case let .saving(since) =
                evaluate(startedAgo: 3600, lastTickAgo: 0.25, lastSaveAgo: -50) else {
            return XCTFail("a future-dated save is clock skew, not a dry window")
        }
        XCTAssertEqual(since, 0, accuracy: 0.001, "clamped, not reported raw")
    }

    // MARK: - Cell 4 — live, quiet window past threshold

    func testLiveTicksWithOldSave_reportsDry() {
        guard case let .dry(seconds) =
                evaluate(startedAgo: 10_900, lastTickAgo: 0.25, lastSaveAgo: 10_800) else {
            return XCTFail("expected .dry")
        }
        XCTAssertEqual(seconds, 10_800, accuracy: 0.001,
                       "the reported duration is the patron-visible loss window")
    }

    func testSaveJustPastDryThreshold_isDry() {
        guard case .dry = evaluate(
            startedAgo: 3600, lastTickAgo: 0.25, lastSaveAgo: threshold + 0.001
        ) else { return XCTFail("just past the threshold must be dry") }
    }

    /// A long stretch that never saved is the worst case, not an exempt one.
    func testLongStretchWithNoSaveEver_reportsDry() {
        guard case let .dry(seconds) = evaluate(startedAgo: 600, lastTickAgo: 0.25) else {
            return XCTFail("ten minutes of playback with no save is the defect")
        }
        XCTAssertEqual(seconds, 600, accuracy: 0.001)
    }

    // MARK: - Cell 5 — the stretch that cannot vouch for itself

    /// The cell an earlier draft of this change got wrong, in the direction
    /// that matters most.
    ///
    /// A tick-stream gap has two causes and this signal cannot separate them:
    /// the patron paused, or playback continued while main-queue delivery was
    /// suppressed. Resolving that toward "paused" and reporting `.saving`
    /// emits an affirmative clean bill of health for the second — which is
    /// PP-4963's own hypothesis, the three-hour locked listen the instrument
    /// exists to catch. Worse, `.saving` is not reported to the fleet at all,
    /// so the false negative would be silent: nothing to see, read as nothing
    /// wrong.
    func testYoungStretchOpenedByAGap_withNoSaveOfItsOwn_reportsTickGap() {
        guard case let .tickGap(seconds) = evaluate(
            startedAgo: 3, lastTickAgo: 0, precededByGap: 10_800
        ) else {
            return XCTFail(
                "a stretch that began because the ticks stopped has not earned "
                + "a health claim, got \(evaluate(startedAgo: 3, lastTickAgo: 0, precededByGap: 10_800))"
            )
        }
        XCTAssertEqual(seconds, 10_800, accuracy: 0.001,
                       "the reported duration is the gap, which is what the fleet "
                       + "needs to tell a pause from a stall in aggregate")
    }

    /// The same young stretch WITHOUT a gap behind it is the ordinary start of
    /// playback, and must stay `.saving`. This is the round-two fix (measure
    /// from the first tick, not session start) and the gap dimension must not
    /// undo it — otherwise every session reports a finding in its first two
    /// minutes.
    func testYoungStretchWithNoGapBehindIt_staysSaving() {
        guard case .saving = evaluate(startedAgo: 3, lastTickAgo: 0) else {
            return XCTFail("a session that simply started is not a finding")
        }
    }

    /// A gap does not outlive the evidence that supersedes it. Once the stretch
    /// has seen a save of its own, it can vouch for itself and how it began
    /// stops mattering — otherwise a patron who pauses once reports `.tickGap`
    /// for the rest of the session.
    func testStretchOpenedByAGap_thatHasSinceSaved_reportsSaving() {
        guard case let .saving(since) = evaluate(
            startedAgo: 90, lastTickAgo: 0, lastSaveAgo: 4, precededByGap: 10_800
        ) else {
            return XCTFail("a save inside this stretch is evidence about this stretch")
        }
        XCTAssertEqual(since, 4, accuracy: 0.001)
    }

    /// And a gapped stretch that has run past the dry threshold with no save
    /// is a `.dry` finding on its own terms — the gap neither upgrades nor
    /// downgrades it. `.dry` outranks `.tickGap` because it is the stronger
    /// statement and this stretch earned it.
    func testStretchOpenedByAGap_quietPastTheThreshold_reportsDryNotTickGap() {
        guard case let .dry(seconds) = evaluate(
            startedAgo: 200, lastTickAgo: 0, precededByGap: 10_800
        ) else {
            return XCTFail("200s of live playback with no save is a dry window, gap or no gap")
        }
        XCTAssertEqual(seconds, 200, accuracy: 0.001,
                       "measured from this stretch's start, not from the gap")
    }

    // MARK: - The scale mismatch this type exists to prevent

    /// A patron plays a minute, pauses three hours, resumes, unlocks 3s later.
    /// The resume starts a NEW stretch, so the save that froze before the
    /// pause is not in scope and cannot be measured against.
    ///
    /// Under the previous `lastSaveAt ?? firstTickAt ?? sessionStartedAt`
    /// chain this reported `.dry(10803)` — a routine gesture manufacturing the
    /// finding, on the ungated fleet signal.
    func testResumeAfterLongPause_isNotReportedDry() {
        guard case let .saving(since) = evaluate(startedAgo: 3, lastTickAgo: 0) else {
            return XCTFail("a fresh stretch after a pause is not a dry window")
        }
        XCTAssertEqual(since, 3, accuracy: 0.001,
                       "measured from the stretch that is actually playing")
    }

    /// And the discrimination that must survive it: one continuous stretch
    /// whose saves died at 60s is still dry. If this ever goes green next to
    /// the test above, the instrument has stopped detecting.
    func testContinuousStretchWithDeadSaves_isStillDry() {
        guard case let .dry(seconds) =
                evaluate(startedAgo: 10_800, lastTickAgo: 0, lastSaveAgo: 10_740) else {
            return XCTFail("three hours of playback with saves dead at 60s IS the defect")
        }
        XCTAssertEqual(seconds, 10_740, accuracy: 0.001)
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
        // live = 600 + 3000 = 3600; restored = 600 → 3000s lost (50 minutes).
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
