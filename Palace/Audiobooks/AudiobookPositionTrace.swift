//
//  AudiobookPositionTrace.swift
//  Palace
//
//  PP-4963: instrumentation for lost audiobook position. The suspected cause is
//  that the autosave, fed by main-runloop timers, stops during long
//  screen-locked playback. A save that does not happen leaves no log, so these
//  policies use a second clock (the player's position stream) to notice when
//  saves went quiet while playback was live, the same pattern as
//  `NowPlayingCoordinator.checkForDryStream()` (code 403).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Save-side dryness

/// What the save path was doing across a background → foreground transition.
enum PositionSaveVerdict: Equatable {
    /// The playback clock never ticked, so nothing can be concluded.
    case noPlayback
    /// Playback stopped before the check, which explains a quiet save window
    /// on its own.
    case playbackStale(sinceLastTick: TimeInterval)
    /// Saves kept pace with playback.
    case saving(sinceLastSave: TimeInterval)
    /// Playback was live and saves had stopped; the duration is the
    /// patron-visible loss window.
    case dry(seconds: TimeInterval)
    /// The tick stream itself went quiet, and the stretch that resumed is too
    /// young to have earned a verdict of its own.
    ///
    /// A tick gap has two causes the stream cannot separate: the patron paused,
    /// or playback continued while main-queue delivery was suppressed (the
    /// PP-4963 hypothesis). Reporting `.saving` would claim health for exactly
    /// the session under suspicion, so the ambiguity is reported instead.
    /// Possible discriminators (position advance across the gap, a `.stopped`
    /// event inside it) are tracked on the ticket.
    case tickGap(seconds: TimeInterval)
    /// The device clock moved backwards between the last tick and this check,
    /// so the tick reference sits AHEAD of `now`.
    ///
    /// Every interval is measured from that reference, so none of them are
    /// meaningful; the regression is reported instead of a verdict.
    case clockRegressed(by: TimeInterval)
}

/// What the recorder observed alongside a verdict, carried to the fleet.
///
/// A single `.tickGap` cannot separate a pause from a stall, but across many
/// sessions the gap counts can. Counts only; no book or patron identity.
struct PositionTraceContext: Equatable {
    let applicationStateAtLastTick: String
    let tickGapCount: Int
    let longestTickGap: TimeInterval
    /// How many ticks arrived with a timestamp earlier than the reference.
    ///
    /// The recorder clamps its reference forward so an out-of-order tick cannot
    /// manufacture a gap; this counts those clamps, once per episode.
    let clockRegressionCount: Int
}

/// What the playback clock observed during ONE continuous stretch of playback.
///
/// The last save is scoped to the stretch that contains it, so a save from
/// before a pause is never measured against playback after it (which would
/// report a pause as a dry window).
struct PlaybackStretch: Equatable {
    /// First tick of THIS stretch. A resume after a gap starts a new one.
    let startedAt: Date
    /// Most recent tick. Freshness is measured from here.
    let lastTickAt: Date
    /// Most recent save observed WITHIN this stretch; nil until one lands.
    let lastSaveAt: Date?
    /// The tick-stream gap that opened this stretch, if one did.
    ///
    /// A stretch that began after a gap cannot support a health claim until it
    /// has evidence of its own. `nil` for the session's first stretch.
    let precededByGap: TimeInterval?

    /// The point the dry window is measured from.
    var lastSignOfLife: Date { lastSaveAt ?? startedAt }
}

/// Decides, on foreground return, whether position saves went quiet WHILE
/// playback was still live.
///
/// "No saves" alone is consistent with a pause, so it is paired with an
/// independent liveness signal. The caller must feed that from
/// `player.positionPublisher` (driven by the playback clock), never from
/// `AudiobookPlaybackModel.$currentLocation` or a timer, which share the
/// runloop mechanism under suspicion and would go quiet with it.
///
/// The decision is a total function over seven reachable cells. "tick fresh"
/// is `ahead` when the reference sits later than `now`, which no interval can
/// be measured from; otherwise `yes`/`no` against `tickFreshness`.
///
///   | stretch | tick fresh | quiet > dryThreshold | saved | gap  | verdict           |
///   |---------|------------|----------------------|-------|------|-------------------|
///   | nil     | —          | —                    | —     | —    | `.noPlayback`     |
///   | present | ahead      | —                    | —     | —    | `.clockRegressed` |
///   | present | no         | —                    | —     | —    | `.playbackStale`  |
///   | present | yes        | yes                  | —     | —    | `.dry`            |
///   | present | yes        | no                   | yes   | —    | `.saving`         |
///   | present | yes        | no                   | no    | nil  | `.saving`         |
///   | present | yes        | no                   | no    | some | `.tickGap`        |
///
/// The last row: a young, unsaved stretch is benign when playback just began,
/// but has no basis for a health claim when it began after a tick gap.
enum PositionSaveDryPolicy {

    /// Comfortably above any legitimate cadence: the throttle saves every ~5s
    /// in the foreground and the toolkit timer's background arm runs at 15s, so
    /// 120s is 8× the slowest healthy interval. Tuned to catch "stopped
    /// entirely", not "ran slowly".
    static let defaultDryThreshold: TimeInterval = 120

    /// `positionPublisher` emits ~4×/s while audio plays, so 10s of silence
    /// means playback genuinely stopped rather than merely stuttered. Also the
    /// rule that ends a stretch: a larger gap is a resume, not a continuation.
    static let defaultTickFreshness: TimeInterval = 10

    static func evaluate(
        now: Date,
        stretch: PlaybackStretch?,
        dryThreshold: TimeInterval = defaultDryThreshold,
        tickFreshness: TimeInterval = defaultTickFreshness
    ) -> PositionSaveVerdict {
        guard let stretch else {
            return .noPlayback
        }

        let sinceLastTick = now.timeIntervalSince(stretch.lastTickAt)

        // Checked first: a negative interval means the reference is ahead of
        // `now` (clock stepped back, or the clamped reference has not been
        // caught up), and every branch below would then read as healthy.
        if sinceLastTick < 0 {
            return .clockRegressed(by: -sinceLastTick)
        }

        if sinceLastTick > tickFreshness {
            // Playback had already stopped when we looked. This deliberately
            // forgoes a real dry window that ENDED before foreground return
            // (locked listen, book finishes at 1h, unlock at 3h): reporting it
            // would require distinguishing "audio ended" from "audio was cut
            // off", which this signal cannot do. Conservative in the direction
            // of under-reporting, so a fleet event means something.
            return .playbackStale(sinceLastTick: sinceLastTick)
        }

        // A stretch that has not saved yet is measured from its own start, so
        // "never saved" is the worst case rather than an exempt one.
        let quietFor = now.timeIntervalSince(stretch.lastSignOfLife)

        // A negative interval is wall-clock skew (NTP step, manual clock
        // change), not a dry window.
        if quietFor > dryThreshold {
            return .dry(seconds: quietFor)
        }

        // A short quiet window only indicates health if the stretch has its
        // own evidence (an observed save, or a clean start). A stretch opened
        // by a tick gap has neither; see `PositionSaveVerdict.tickGap`.
        if stretch.lastSaveAt == nil, let gap = stretch.precededByGap {
            return .tickGap(seconds: gap)
        }
        return .saving(sinceLastSave: max(0, quietFor))
    }
}

// MARK: - Restore-side gap

/// The last position the PLAYBACK CLOCK observed, persisted so it survives the
/// app being terminated mid-listen.
///
/// Recorded on the playback-clock cadence, never on save (which would make the
/// restore gap zero by construction). Diagnostic only; the restore path does
/// not read it.
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
    ///   from the loaded manifest. Injected so the decision stays pure and
    ///   testable without a toolkit `Tracks` graph.
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
        // An unresolvable key must never fall through to `.aligned`: that would
        // report a healthy restore for the book that lost its place.
        guard let liveOffset = absoluteOffset(marker.trackKey, marker.timestamp) else {
            return .markerUnresolvable(trackKey: marker.trackKey)
        }
        guard let restoredOffset = absoluteOffset(restoredTrackKey, restoredTimestamp) else {
            return .markerUnresolvable(trackKey: restoredTrackKey)
        }

        let gap = liveOffset - restoredOffset

        // Clamped so `abs(gap) > band` implies `gap != 0` for the sign test.
        let band = max(0, tolerance)
        guard abs(gap) > band else {
            return .aligned(driftSeconds: gap)
        }
        return gap > 0 ? .behind(seconds: gap) : .ahead(seconds: -gap)
    }
}
