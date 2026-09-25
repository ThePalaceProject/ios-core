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
    /// The tick stream itself went quiet, and the stretch that resumed is too
    /// young to have earned a verdict of its own.
    ///
    /// This case exists because the alternative was a lie. A gap in the ticks
    /// has two causes that the tick stream cannot tell apart: the patron
    /// paused, or playback continued while delivery was suppressed — and the
    /// second is PP-4963's own hypothesis, since `positionPublisher` is driven
    /// by the playback clock but DELIVERS on the main queue. Treating a gap as
    /// a pause and reporting `.saving` would emit an affirmative "healthy" for
    /// the exact three-hour locked session the instrument exists to catch.
    ///
    /// Two discriminators do exist, and this case is not a claim that they
    /// don't — it is what the recorder reports until one is wired in.
    /// `AudiobookPositionOffsets.resolver` already converts a (trackKey,
    /// timestamp) pair to an absolute book offset, summing intervening track
    /// durations, so the position DOES survive a track boundary and a position
    /// that advanced across the gap means playback continued. And
    /// `OpenAccessPlayer.pause()` publishes `.stopped` on a plain
    /// `PassthroughSubject` from a global queue, so a wedged main thread
    /// cannot suppress it: a `.stopped` inside the gap means a pause, and its
    /// absence means a stall.
    ///
    /// Both are one-way and partial — a seek during a pause confounds the
    /// first, Findaway differs on the second, and `.stopped` is conditional on
    /// a non-nil track position — so wiring either is its own change with its
    /// own failure mode, tracked on the ticket. Until then the honest verdict
    /// is that this instrument did not see.
    ///
    /// So the ambiguity is reported instead of resolved — the same discipline
    /// as `.playbackStale` over a silent `.dry`, and `.markerUnresolvable` over
    /// `.aligned`. It is also a finding in its own right: a gap means the
    /// instrument went blind, which is the branch's one unverified assumption
    /// (that `positionPublisher` survives a locked screen) failing out loud
    /// rather than passing as health.
    case tickGap(seconds: TimeInterval)
}

/// What the recorder observed alongside a verdict, carried to the fleet.
///
/// `.tickGap` on its own cannot separate an overnight pause from an overnight
/// stall — the two produce identical inputs, and no single session can tell
/// them apart. Across many sessions they do separate: pausing leaves a handful
/// of gaps, a delivery path that stalls leaves many or one enormous one. These
/// counters are what makes that comparison possible. Both are counts of the
/// device's own behaviour and carry no book or patron identity.
struct PositionTraceContext: Equatable {
    let applicationStateAtLastTick: String
    let tickGapCount: Int
    let longestTickGap: TimeInterval
}

/// What the playback clock observed during ONE continuous stretch of playback.
///
/// This type exists to make a defect class unrepresentable rather than
/// reconciled. The three facts the verdict needs — when this stretch began,
/// when it was last alive, and when a save was last seen — used to be three
/// independent `Date?`s on three different scales, combined by a precedence
/// chain at read time:
///
///   `lastSaveAt ?? firstTickAt ?? sessionStartedAt`
///
/// `lastSaveAt` is frozen while paused, because its only writer is gated on
/// `isPlaying`. `firstTickAt` tracked the current stretch. `sessionStartedAt`
/// tracked the whole session. Reading them in precedence order silently mixed
/// scales: a patron who played a minute, paused three hours, resumed and
/// unlocked was measured against the save that froze before the pause, and the
/// instrument reported a three-hour dry window for a perfectly healthy
/// session — on the UNGATED fleet signal, from a routine gesture.
///
/// Scoping the save to the stretch that contains it removes the mismatch at
/// the source. A new stretch starts with no save, so a save from a previous
/// stretch cannot be compared against this one; there is nothing left to
/// reconcile, and no `max()` to get wrong. `sessionStartedAt` disappeared
/// entirely — it was only ever a fallback for a case that cannot occur.
struct PlaybackStretch: Equatable {
    /// First tick of THIS stretch. A resume after a gap starts a new one.
    let startedAt: Date
    /// Most recent tick. Freshness is measured from here.
    let lastTickAt: Date
    /// Most recent save observed WITHIN this stretch; nil until one lands.
    let lastSaveAt: Date?
    /// The tick-stream gap that opened this stretch, if one did.
    ///
    /// Carried rather than discarded because a stretch that began after a gap
    /// cannot support a health claim until it has run long enough to produce
    /// its own evidence. `nil` for the first stretch of a session, which began
    /// because playback began — not because anything went quiet.
    let precededByGap: TimeInterval?

    /// The point the dry window is measured from. Both candidates are
    /// stretch-scoped, so this is a same-scale choice rather than a
    /// cross-scale reconciliation.
    var lastSignOfLife: Date { lastSaveAt ?? startedAt }
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
/// playback clock. Its SOURCE is independent of the runloop, so it survives the
/// NSTimer coalescing under test; whether it survives a three-hour lock is the
/// measurement this exists to take, not an assumption it may rest on.
/// It must NOT come from `AudiobookPlaybackModel.$currentLocation` (fed by both
/// the playback clock AND the suspect runloop timer) and must not come from a
/// timer of its own. A watchdog driven by the mechanism it is watching goes
/// silent exactly when the defect fires, and its silence would then read as
/// `.noPlayback` — the instrument would quietly report the absence of a defect
/// it had merely lost the ability to see.
///
/// The decision is a total function over five reachable cells:
///
///   | stretch | tick fresh | quiet > dryThreshold | saved | gap  | verdict          |
///   |---------|------------|----------------------|-------|------|------------------|
///   | nil     | —          | —                    | —     | —    | `.noPlayback`    |
///   | present | no         | —                    | —     | —    | `.playbackStale` |
///   | present | yes        | yes                  | —     | —    | `.dry`           |
///   | present | yes        | no                   | yes   | —    | `.saving`        |
///   | present | yes        | no                   | no    | nil  | `.saving`        |
///   | present | yes        | no                   | no    | some | `.tickGap`       |
///
/// The last row is the one that earns its keep, and it is the cell an earlier
/// draft got wrong. A young stretch with no save of its own is benign when it
/// began because playback began, and is NOT benign when it began because the
/// tick stream went quiet — in the second case the instrument has no basis for
/// a health claim and must not make one. Everything above that row is
/// unchanged by the addition of the gap dimension: a stretch that has saved,
/// or has already run past the dry threshold, has its own evidence and does
/// not care how it started.
///
/// Five cells, each with its boundary. That is the whole state space — which
/// is the point of taking a `PlaybackStretch?` rather than five loose dates.
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

        // Short quiet window. That is only evidence of health if this stretch
        // has evidence of its own — a save it actually observed, or a clean
        // birth. A stretch opened by a gap in the tick stream has neither, and
        // the gap has two causes this signal cannot separate: the patron
        // paused, or playback continued while delivery was suppressed. Saying
        // `.saving` here would emit an affirmative "healthy" for the second,
        // which is PP-4963's own hypothesis — and `.saving` is not reported to
        // the fleet at all, so that claim would be silent as well as wrong.
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
