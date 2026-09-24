//
//  AudiobookPositionTrace.swift
//  Palace
//
//  PP-4963 — instrumentation for "the app forgot where I was."
//
//  WHY THIS EXISTS
//
//  25 of 83 App Store reviews this year report losing hours of audiobook
//  position. Four fixes shipped across 3.2.x/3.3.0 without moving the
//  complaint volume. Reading the source suggests the autosave stops during
//  long screen-locked background playback — the chain is two main-runloop
//  stages (`AudiobookManager.setupNowPlayingInfoTimer`'s
//  `Timer.publish(on: .main, in: .common)` feeding
//  `AudiobookPlaybackModel`'s `.throttle(5s, scheduler: RunLoop.main)`), and
//  the toolkit's own comment says iOS coalesces and suspends such timers when
//  the screen is locked. But that is a reading, and the previous four fixes
//  were each written with confidence too.
//
//  Crashlytics cannot answer it as-is: it records failures, and a save that
//  does not happen is an ABSENCE. Nothing logs its own absence from inside the
//  thing that stopped running. The only way absence becomes an event is a
//  second clock, still running, noticing the first went quiet — which is
//  exactly what `NowPlayingCoordinator.checkForDryStream()` (code 403) already
//  does for the lock-screen writer. These policies apply that shipping pattern
//  to the save path.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Save-side dryness

/// What the save path was doing across a background → foreground transition.
enum PositionSaveVerdict: Equatable {
    /// The playback clock never ticked, so nothing can be concluded. Distinct
    /// from every other case on purpose — see `PositionSaveDryPolicy`.
    case noPlayback
    /// Playback stopped before the check, which explains a quiet save window
    /// on its own.
    case playbackStale(sinceLastTick: TimeInterval)
    /// Saves kept pace with playback.
    case saving(sinceLastSave: TimeInterval)
    /// Playback was demonstrably live and saves had stopped. This is the
    /// finding PP-4963 exists to confirm or refute; the duration is the
    /// patron-visible loss window.
    case dry(seconds: TimeInterval)
}

/// Decides, on foreground return, whether position saves went quiet WHILE
/// playback was still live.
///
/// The two-signal shape is load-bearing. "No saves for three hours" on its own
/// is ambiguous — it is equally consistent with the defect and with the patron
/// having simply paused. Pairing it with an independent liveness signal is what
/// makes the measurement mean something.
///
/// Which liveness signal is just as load-bearing, and belongs to the caller:
/// it MUST come from `player.positionPublisher`, which AVPlayer drives from the
/// playback clock and which the OS keeps firing while backgrounded and locked.
/// It must NOT come from `AudiobookPlaybackModel.$currentLocation` (fed by both
/// the playback clock AND the suspect runloop timer) and must not come from a
/// timer of its own. A watchdog driven by the mechanism it is watching goes
/// silent exactly when the defect fires, and its silence would then read as
/// `.noPlayback` — the instrument would quietly report the absence of a defect
/// it had merely lost the ability to see.
enum PositionSaveDryPolicy {

    /// Comfortably above any legitimate cadence: the throttle saves every ~5s
    /// in the foreground and the toolkit timer's background arm runs at 15s, so
    /// 120s is 8× the slowest healthy interval. Tuned to catch "stopped
    /// entirely", not "ran slowly".
    static let defaultDryThreshold: TimeInterval = 120

    /// `positionPublisher` emits ~4×/s while audio plays, so 10s of silence
    /// means playback genuinely stopped rather than merely stuttered.
    static let defaultTickFreshness: TimeInterval = 10

    static func evaluate(
        now: Date,
        sessionStartedAt: Date,
        lastTickAt: Date?,
        lastSaveAt: Date?,
        dryThreshold: TimeInterval = defaultDryThreshold,
        tickFreshness: TimeInterval = defaultTickFreshness
    ) -> PositionSaveVerdict {
        guard let lastTickAt else {
            return .noPlayback
        }

        let sinceLastTick = now.timeIntervalSince(lastTickAt)
        if sinceLastTick > tickFreshness {
            // Playback had already stopped when we looked. This deliberately
            // forgoes a real dry window that ENDED before foreground return
            // (locked listen, book finishes at 1h, unlock at 3h): reporting it
            // would require distinguishing "audio ended" from "audio was cut
            // off", which this signal cannot do. Conservative in the direction
            // of under-reporting, so a fleet event means something.
            return .playbackStale(sinceLastTick: sinceLastTick)
        }

        // A session that has never saved is the worst case, not an exempt one,
        // so it is measured from session start rather than skipped.
        let reference = lastSaveAt ?? sessionStartedAt
        let quietFor = now.timeIntervalSince(reference)

        // A negative interval is wall-clock skew (NTP step, manual clock
        // change), not a dry window.
        guard quietFor > dryThreshold else {
            return .saving(sinceLastSave: max(0, quietFor))
        }
        return .dry(seconds: quietFor)
    }
}

// MARK: - Restore-side gap

/// The last position the PLAYBACK CLOCK observed, persisted so it survives the
/// app being terminated mid-listen.
///
/// Recorded on the playback-clock cadence and never on save. Updating it when a
/// save happens would make the restore gap identically zero by construction —
/// the instrument would agree with itself and measure nothing.
///
/// Diagnostic only. Nothing reads this to decide where to open a book; the
/// restore path is `resolveInitialPosition` and stays unchanged.
struct LastLivePositionMarker: Codable, Equatable, Sendable {
    let bookID: String
    let trackKey: String
    let timestamp: Double
    let recordedAt: Date
}

/// How far the position we actually restored sits from the last position we
/// saw live. This is the number patrons are describing when they say they came
/// back three hours behind.
enum PositionRestoreGapVerdict: Equatable {
    case noMarker
    case markerForDifferentBook
    /// A track key that is not in the loaded manifest. Reported rather than
    /// folded into `.aligned` — see `PositionRestoreGapPolicy`.
    case markerUnresolvable(trackKey: String)
    case aligned(driftSeconds: Double)
    /// Restored EARLIER than the last live position: time the patron lost.
    case behind(seconds: Double)
    /// Restored LATER than the last live position. Not the complaint, but a
    /// real signal (a stale remote winning over a newer local), so it keeps its
    /// own case instead of being dropped.
    case ahead(seconds: Double)
}

enum PositionRestoreGapPolicy {

    /// The save throttle is 5s, so a few seconds of drift is normal operation.
    /// 10s keeps healthy sessions quiet while the complaint is measured in
    /// minutes and hours.
    static let defaultTolerance: Double = 10

    /// - Parameter absoluteOffset: maps `(trackKey, timestamp)` to an offset
    ///   from the start of the book, returning nil when the track is absent
    ///   from the loaded manifest. Injected rather than taking a table of
    ///   contents so the decision stays a pure function over a small input
    ///   space, and so cross-track arithmetic is exercised without building a
    ///   toolkit `Tracks` graph.
    static func evaluate(
        marker: LastLivePositionMarker?,
        bookID: String,
        restoredTrackKey: String,
        restoredTimestamp: Double,
        absoluteOffset: (_ trackKey: String, _ timestamp: Double) -> Double?,
        tolerance: Double = defaultTolerance
    ) -> PositionRestoreGapVerdict {
        guard let marker else {
            return .noMarker
        }
        guard marker.bookID == bookID else {
            return .markerForDifferentBook
        }
        // An unresolvable key must never fall through to `.aligned`. Treating a
        // position that cannot be located as agreement is the 3.2.3 Cause 2
        // shape, and here it would report a healthy restore for exactly the
        // book that lost its place.
        guard let liveOffset = absoluteOffset(marker.trackKey, marker.timestamp) else {
            return .markerUnresolvable(trackKey: marker.trackKey)
        }
        guard let restoredOffset = absoluteOffset(restoredTrackKey, restoredTimestamp) else {
            return .markerUnresolvable(trackKey: restoredTrackKey)
        }

        let gap = liveOffset - restoredOffset

        // A negative tolerance is meaningless here — it would make `.aligned`
        // unreachable and let a gap of exactly zero fall into the sign test
        // below, where zero has no correct answer. Clamping removes that
        // degree of freedom, and in doing so makes `abs(gap) > band` imply
        // `gap != 0`, so `gap > 0` has no reachable boundary case.
        let band = max(0, tolerance)
        guard abs(gap) > band else {
            return .aligned(driftSeconds: gap)
        }
        return gap > 0 ? .behind(seconds: gap) : .ahead(seconds: -gap)
    }
}
