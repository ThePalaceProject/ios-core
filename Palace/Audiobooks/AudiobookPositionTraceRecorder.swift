//
//  AudiobookPositionTraceRecorder.swift
//  Palace
//
//  PP-4963 — the live half of the position instrumentation. The decisions are
//  in `AudiobookPositionTrace.swift`; this holds the two clocks those
//  decisions compare and decides where a verdict goes.
//
//  Two sinks, for two different readers:
//
//  - Crashlytics gets ONLY the findings (`.dry`, `.behind`), carrying a
//    duration and an app state and no book, title, or patron identity. Patron
//    reading position is a library record and does not belong in fleet
//    telemetry; the duration is the entire question PP-4963 asks. This mirrors
//    `NowPlayingCoordinator`'s code-403 detector, which ships ungated for the
//    same reason.
//  - The per-book `AudiobookFileLogger` gets the full local trace, including
//    the periodic heartbeat that proves the recorder was alive during a locked
//    listen. That file never leaves the device unless the patron emails their
//    logs. It is gated on a developer switch that defaults OFF
//    (`DebugSettings.isAudiobookPositionTraceEnabled`) because it writes on
//    every save — about every five seconds of playback — which is the right
//    cost for a measurement run and the wrong one for the install base.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import UIKit
import PalaceAudiobookToolkit
import PalaceLogging

/// Emits one fleet finding. Carries the error code so the seam cannot erase the
/// distinction between the dry-save signal (404) and the restore-gap one (405).
typealias FleetEventEmitting = (TPPErrorCode, String, [String: Any]?) -> Void

// MARK: - Marker persistence

/// Storage seam for the last-live marker. A protocol so tests can observe
/// exactly when a write happens — the cadence is the measurement.
protocol LastLivePositionMarkerStoring: Sendable {
    func marker(forBookID bookID: String) -> LastLivePositionMarker?
    func save(_ marker: LastLivePositionMarker)
}

/// `UserDefaults`-backed marker store. One small JSON blob per book.
///
/// Deliberately NOT the book registry: the registry is the restore source, and
/// a diagnostic that wrote there could change where a book opens. This is
/// write-only from the app's point of view — nothing but the trace reads it.
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which
/// Apple documents as thread-safe, and this type adds no mutable state of its
/// own. The store is read and written from the player's thread as well as the
/// main one, so the conformance is load-bearing rather than cosmetic.
struct UserDefaultsLastLivePositionMarkerStore: LastLivePositionMarkerStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    fileprivate static let keyPrefix = "audiobook.lastLivePosition."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ bookID: String) -> String { Self.keyPrefix + bookID }

    func marker(forBookID bookID: String) -> LastLivePositionMarker? {
        guard let data = defaults.data(forKey: key(bookID)) else { return nil }
        return try? JSONDecoder().decode(LastLivePositionMarker.self, from: data)
    }

    func save(_ marker: LastLivePositionMarker) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        defaults.set(data, forKey: key(marker.bookID))
    }

    /// Removes every stored marker. Called when the trace is switched OFF so a
    /// patron's positions do not outlive the switch that authorised recording
    /// them — the Developer Settings screen is reachable in App Store builds
    /// via the version-number long-press, so "developer-only" is not the same
    /// as "never on a patron's device", and nothing else purges these keys.
    func purgeAll() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Manifest offsets

/// Builds the offset resolver `PositionRestoreGapPolicy` needs.
///
/// Lives here rather than on `AudiobookSessionManager` for two reasons: that
/// type is a frozen god-class under the Wave 0 decomposition ratchet, and this
/// is position arithmetic, which belongs with the rest of the position trace.
enum AudiobookPositionOffsets {

    /// Maps a track key and timestamp to an offset in seconds from the start
    /// of the book, or nil when the loaded manifest contains no such track.
    ///
    /// Returning nil rather than a best guess is what lets the policy report
    /// `.markerUnresolvable` instead of quietly reporting agreement — the
    /// 3.2.3 Cause 2 shape, where a position that cannot be located is treated
    /// as though it matched.
    ///
    /// The arithmetic is the toolkit's own `TrackPosition` subtraction, which
    /// sums intervening track durations, so a gap spanning a track boundary is
    /// measured rather than truncated.
    static func resolver(
        for tableOfContents: AudiobookTableOfContents
    ) -> (_ trackKey: String, _ timestamp: Double) -> Double? {
        { trackKey, timestamp in
            let tracks = tableOfContents.tracks
            guard let track = tracks.tracks.first(where: { $0.key == trackKey }),
                  let firstTrack = tracks.tracks.first
            else {
                return nil
            }
            let position = TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
            let bookStart = TrackPosition(track: firstTrack, timestamp: 0, tracks: tracks)
            return try? position - bookStart
        }
    }
}

// MARK: - Recorder

/// Holds the two clocks whose disagreement is the finding: when a position was
/// last SAVED, and when the playback clock was last seen alive.
///
/// `@unchecked Sendable` with an `NSLock` rather than `@MainActor`: the tick
/// signal arrives ~4×/s and `AudiobookBookmarkBusinessLogic` saves from
/// whatever thread the player is on, so actor hops would mean a `Task` per tick
/// for no benefit. Every mutable property below is touched only under `lock`,
/// and reports are dispatched outside it — with one documented exception:
/// `cancellables` is written only by `observe(positionPublisher:)`, which is
/// called exactly once during session construction, before any tick or save can
/// arrive. It is not lock-protected because it is not shared.
final class AudiobookPositionTraceRecorder: @unchecked Sendable {

    /// How often the last-live marker is rewritten. `positionPublisher` emits
    /// ~4×/s; persisting at that rate would be pure write amplification, and a
    /// minute of granularity is far below the minutes-to-hours gap patrons
    /// report.
    static let markerWriteInterval: TimeInterval = 60

    /// The one tick-freshness value in the system. A gap larger than this ends
    /// a stretch here, and the same constant decides staleness in
    /// `PositionSaveDryPolicy.evaluate`.
    ///
    /// Deliberately NOT a separate knob. The two boundaries answer the same
    /// question — "has the tick stream gone quiet?" — and a caller that moved
    /// one without the other would split the recorder's idea of a stretch from
    /// the policy's idea of staleness, with no compile error and no test
    /// failure to show for it. `evaluate` still takes `tickFreshness` so its
    /// own boundary tests can drive both sides of it; production has exactly
    /// one caller and it passes the default.
    static let tickFreshnessWindow: TimeInterval = PositionSaveDryPolicy.defaultTickFreshness

    /// Serial and utility-QoS: trace writes must stay ordered relative to each
    /// other, and must never contend with playback or the save path.
    private static let fileLogQueue = DispatchQueue(
        label: "org.thepalaceproject.audiobook-position-trace",
        qos: .utility
    )

    /// How the shipped recorder decides whether the local trace is on.
    ///
    /// Named and static so the init default and any test read the SAME code
    /// rather than two copies that agree by coincidence. Measured: with this
    /// inline, a test that re-implemented the expression passed while the
    /// production closure returned `false` unconditionally.
    static func defaultDiagnosticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        DebugSettings(defaults: defaults).isAudiobookPositionTraceEnabled
    }

    private let bookID: String
    private let markerStore: LastLivePositionMarkerStoring
    private let diagnosticsEnabled: () -> Bool
    private let reportSaveVerdict: (PositionSaveVerdict, PositionTraceContext) -> Void
    private let reportGapVerdict: (PositionRestoreGapVerdict) -> Void
    private let fileLog: (String) -> Void
    // No stored emitter: the two report closures capture it directly. A stored
    // copy was written and never read, which also meant injecting both it and
    // `reportSaveVerdict` silently ignored the former.
    private let now: () -> Date

    private let lock = NSLock()
    /// The current stretch of playback, or nil before the first tick. One
    /// value rather than four loose dates: see `PlaybackStretch` for why the
    /// save must be scoped to the stretch that contains it.
    private var stretch: PlaybackStretch?
    private var lastMarkerWriteAt: Date = .distantPast
    /// App state as seen by the most recent playback tick. See `notePlaybackTick`.
    private var lastObservedAppState: String = "unknown"
    /// How many times the tick stream went quiet long enough to open a new
    /// stretch, and the worst such gap. Aggregate rather than per-stretch: a
    /// healthy session pauses a handful of times, while a stalled delivery
    /// path produces many gaps or one enormous one. That distinction is what
    /// separates the two causes of a gap ACROSS the fleet, which is the
    /// question PP-4963 has to answer and no single session can.
    private var tickGapCount: Int = 0
    private var clockRegressionCount: Int = 0
    /// Whether the last tick was already behind the reference, so a single
    /// clock step counts once rather than once per tick. At roughly four ticks
    /// a second a thirty-minute step would otherwise report ~7,200 alongside
    /// `tickGapCount`, which counts events — two numbers in one payload
    /// measuring different things in the same units.
    private var inClockRegression = false
    private var longestTickGap: TimeInterval = 0

    private var cancellables = Set<AnyCancellable>()

    init(
        bookID: String,
        markerStore: LastLivePositionMarkerStoring = UserDefaultsLastLivePositionMarkerStore(),
        diagnosticsEnabled: @escaping () -> Bool = { AudiobookPositionTraceRecorder.defaultDiagnosticsEnabled() },
        reportSaveVerdict: ((PositionSaveVerdict, PositionTraceContext) -> Void)? = nil,
        reportGapVerdict: ((PositionRestoreGapVerdict) -> Void)? = nil,
        fileLog: ((String) -> Void)? = nil,
        emitFleetEvent: FleetEventEmitting? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.bookID = bookID
        self.markerStore = markerStore
        self.diagnosticsEnabled = diagnosticsEnabled
        // The CODE is part of the seam. It was previously hard-coded to
        // `.audiobookPositionSaveDry` here, which made code 405 unreachable and
        // filed every restore-gap finding under the dry-save code — collapsing
        // the two signals this exists to keep apart. A seam below code
        // selection cannot be tested for the distinction it erases.
        let emit: FleetEventEmitting = emitFleetEvent ?? { code, summary, metadata in
            TPPErrorLogger.logError(withCode: code, summary: summary, metadata: metadata)
        }
        // Wrapped rather than referenced bare: a bare reference to a function
        // carrying a defaulted parameter crashes the Swift frontend.
        self.reportSaveVerdict = reportSaveVerdict ?? { verdict, context in
            Self.crashlyticsSaveReport(verdict, context: context, emit: emit)
        }
        self.reportGapVerdict = reportGapVerdict ?? { verdict in
            Self.crashlyticsGapReport(verdict, emit: emit)
        }
        self.fileLog = fileLog ?? { [bookID] line in
            // Hopped off the caller's thread, which is the MAIN actor: both
            // `noteSave` call sites sit in `AudiobookBookmarkBusinessLogic`,
            // reached from the `@MainActor` `DefaultAudiobookManager`.
            //
            // `AudiobookFileLogger.logEvent` is synchronous and not cheap — an
            // unthrottled directory enumeration with per-file `resourceValues`,
            // a `fileExists`, an `attributesOfItem`, and a FileHandle
            // open/seek/write/close. Inline on the main thread at save cadence
            // (~every 5s of playback) that is main-thread disk I/O added to the
            // critical save path.
            //
            // It would also corrupt the measurement. PP-4963 asks whether saves
            // keep firing during long locked playback; a trace run that adds
            // synchronous I/O to every save is measuring a save path the
            // instrument itself changed. A watchdog must not perturb what it
            // watches — the same reason the liveness signal is taken from
            // `positionPublisher` rather than the timer under test.
            //
            // Serial, so trace lines keep their order in the file.
            Self.fileLogQueue.async {
                AudiobookFileLogger.shared.logEvent(forBookId: bookID, event: line)
            }
        }
        self.now = now
    }

    // MARK: - Signals in

    /// Called after a position is written to the LOCAL registry — the write
    /// that decides whether the patron keeps their place. The remote annotation
    /// post is a separate defect and is deliberately not what this measures.
    func noteSave(at date: Date) {
        lock.lock()
        // A save belongs to the stretch it happened in. With no stretch there
        // is no playback to measure it against, and the verdict is
        // `.noPlayback` regardless — so there is nowhere to put it and nothing
        // lost by not inventing a home.
        if let current = stretch {
            stretch = PlaybackStretch(
                startedAt: current.startedAt,
                lastTickAt: current.lastTickAt,
                lastSaveAt: date,
                precededByGap: current.precededByGap
            )
        }
        let state = lastObservedAppState
        lock.unlock()

        // The gate is checked BEFORE the interpolation, not inside traceLine.
        // Swift evaluates an interpolated argument at the call site, so the
        // earlier form allocated an ISO8601DateFormatter on every save — about
        // every five seconds of playback — for every patron, including the
        // overwhelming majority who never turn the trace on.
        guard diagnosticsEnabled() else { return }
        traceLine("save at=\(Self.stamp(date)) state=\(state)")
    }

    /// Called from `player.positionPublisher` — AVPlayer's periodic time
    /// observer, driven by the playback clock. This is the signal that keeps
    /// arriving while the screen is locked, and the reason the recorder can
    /// tell "saves stopped" from "playback stopped".
    func notePlaybackTick(trackKey: String, timestamp: Double, at date: Date) {
        // Captured on the tick rather than at foreground return, where the
        // state is `.active` by definition — a constant that would look like a
        // measured field.
        let state = Self.applicationStateName()

        lock.lock()
        // A gap longer than the freshness window is a RESUME, so it starts a
        // new stretch — which drops the previous stretch's save with it. That
        // is the point: a save from before a three-hour pause is not evidence
        // about the stretch that just began, and comparing against it reported
        // a dry window for a healthy session.
        // The gap is CARRIED, not just acted on. Opening a new stretch throws
        // away the previous save, which is right for a pause and wrong for a
        // stalled tick stream — and this predicate cannot tell those apart.
        // Recording the gap on the stretch lets the policy decline to make a
        // health claim it has not earned, instead of guessing.
        let gap = stretch.map { date.timeIntervalSince($0.lastTickAt) }
        if let gap, gap < 0 {
            if !inClockRegression {
                clockRegressionCount += 1
                inClockRegression = true
            }
        } else {
            inClockRegression = false
        }
        let isResume = gap.map { $0 > Self.tickFreshnessWindow } ?? true
        if isResume {
            if let gap {
                tickGapCount += 1
                longestTickGap = max(longestTickGap, gap)
            }
            stretch = PlaybackStretch(
                startedAt: date,
                lastTickAt: date,
                lastSaveAt: nil,
                precededByGap: gap
            )
        } else if let current = stretch {
            stretch = PlaybackStretch(
                startedAt: current.startedAt,
                // NEVER backwards. A tick delivered out of order, or after the
                // wall clock steps back (an NTP correction mid-playback), would
                // otherwise regress the reference — and the next ordinary tick
                // would then measure its gap from that earlier point, read as a
                // resume, open a new stretch and drop the save with it. The
                // result is a spurious `.tickGap` on a session that never
                // stopped playing, produced by the clock rather than by
                // anything the patron did.
                // Clamped forward, and counted. A single out-of-order tick
                // must not manufacture a gap; counting the clamp is what makes
                // a session that hit one identifiable in the trace. A
                // sustained backwards step holds the reference ahead of now,
                // which `PositionSaveDryPolicy` declines to measure from.
                lastTickAt: max(current.lastTickAt, date),
                lastSaveAt: current.lastSaveAt,
                precededByGap: current.precededByGap
            )
        }
        // Snapshotted under the lock: the trace line below runs outside it, and
        // these two are mutated by every tick on whichever thread delivers.
        let boundaryGap = isResume ? gap : nil
        let gapCountSoFar = tickGapCount
        let longestGapSoFar = longestTickGap
        lastObservedAppState = state
        let shouldWriteMarker = date.timeIntervalSince(lastMarkerWriteAt) >= Self.markerWriteInterval
        if shouldWriteMarker {
            lastMarkerWriteAt = date
        }
        lock.unlock()

        // A stretch boundary is the one event a deliberate trace run most needs
        // and the only one nothing recorded. Without it the log shows an
        // unbroken column of ticks whether the patron paused for three hours or
        // the tick stream stalled for three hours, and the device trace PP-4963
        // is waiting on cannot tell the two readings apart after the fact.
        // Gated like every other trace line, so it costs nothing by default.
        if let boundaryGap {
            // Through `traceLine`, not `fileLog` directly. The per-book log is
            // read by filtering on the `[AUDIOPOS-TRACE]` prefix, which a direct
            // write does not carry — so the one line a device run most needs to
            // tell a pause from a stall would be the one line the filter drops.
            // `traceLine` also applies the same gate.
            traceLine("stretch boundary after \(String(format: "%.1f", boundaryGap))s "
                      + "without a tick (gap #\(gapCountSoFar), "
                      + "longest \(String(format: "%.1f", longestGapSoFar))s)")
        }

        guard shouldWriteMarker else { return }

        // The marker is persisted ONLY while the trace is switched on. It
        // records where a patron was in a book, which is a library record: left
        // ungated it would be written for every patron, survive the sign-out
        // purge that exists to remove exactly that, and grow without bound as
        // books are played. The cost is that the restore-gap signal (405)
        // reports only during a deliberate trace run; the dry-save signal (404),
        // which carries no patron data, stays fleet-wide.
        guard diagnosticsEnabled() else { return }

        markerStore.save(LastLivePositionMarker(
            bookID: bookID,
            trackKey: trackKey,
            timestamp: timestamp,
            recordedAt: date
        ))
        traceLine("live track=\(trackKey) t=\(String(format: "%.1f", timestamp)) state=\(state)")
    }

    // MARK: - Verdicts out

    /// Evaluated on foreground return, the one moment we can compare the two
    /// clocks and still be running.
    func applicationDidBecomeActive() {
        // `now()` is injected and therefore arbitrary code; called outside the
        // lock so a caller's clock cannot deadlock the recorder.
        let at = now()

        lock.lock()
        let verdict = PositionSaveDryPolicy.evaluate(now: at, stretch: stretch)
        let context = PositionTraceContext(
            applicationStateAtLastTick: lastObservedAppState,
            tickGapCount: tickGapCount,
            longestTickGap: longestTickGap,
            clockRegressionCount: clockRegressionCount
        )
        lock.unlock()

        traceLine("verdict \(verdict) stateAtLastTick=\(context.applicationStateAtLastTick) "
                  + "gaps=\(context.tickGapCount) longestGap=\(String(format: "%.1f", context.longestTickGap))")
        reportSaveVerdict(verdict, context)
    }

    /// Convenience over the resolver-taking form below, so the call site does
    /// not have to name toolkit types or build the offset closure itself.
    func evaluateRestoreGap(
        restoredPosition: TrackPosition,
        in tableOfContents: AudiobookTableOfContents
    ) {
        evaluateRestoreGap(
            restoredTrackKey: restoredPosition.track.key,
            restoredTimestamp: restoredPosition.timestamp,
            absoluteOffset: AudiobookPositionOffsets.resolver(for: tableOfContents)
        )
    }

    /// Compares the position actually restored against the last position the
    /// playback clock saw. `absoluteOffset` maps a track key and timestamp to
    /// an offset from the start of the book, returning nil for a key the loaded
    /// manifest does not contain.
    func evaluateRestoreGap(
        restoredTrackKey: String,
        restoredTimestamp: Double,
        absoluteOffset: (_ trackKey: String, _ timestamp: Double) -> Double?
    ) {
        let verdict = PositionRestoreGapPolicy.evaluate(
            marker: markerStore.marker(forBookID: bookID),
            bookID: bookID,
            restoredTrackKey: restoredTrackKey,
            restoredTimestamp: restoredTimestamp,
            absoluteOffset: absoluteOffset
        )

        traceLine("restore \(verdict) at track=\(restoredTrackKey) t=\(String(format: "%.1f", restoredTimestamp))")
        reportGapVerdict(verdict)
    }

    // MARK: - Production wiring

    /// Subscribes the liveness signal and the foreground trigger.
    ///
    /// The publisher MUST be `player.positionPublisher`. Anything runloop-fed —
    /// `AudiobookPlaybackModel.$currentLocation` included, since it carries
    /// both the playback clock and the suspect timer — would stop arriving
    /// under exactly the conditions being measured, and the recorder would then
    /// report `.noPlayback`: a clean result for a defect it had merely gone
    /// blind to.
    ///
    /// Precisely: the SOURCE is independent of the runloop —
    /// `addPeriodicTimeObserver` on the AV player, and Findaway's progress
    /// callback — but both DELIVER on the main queue. This therefore survives
    /// the NSTimer coalescing that is the suspect here; it does NOT survive a
    /// wedged main thread. Do not read it as a guarantee of the latter.
    /// - Parameter notificationCenter: injectable so a test can drive the real
    ///   subscription without broadcasting `didBecomeActiveNotification` to the
    ///   whole app — a global post also wakes `NowPlayingCoordinator` (which can
    ///   emit a 403) and `DownloadThrottlingService` on the main queue, landing
    ///   in whichever test runs next.
    func observe(
        positionPublisher: AnyPublisher<TrackPosition, Never>,
        notificationCenter: NotificationCenter = .default
    ) {
        positionPublisher
            .sink { [weak self] position in
                guard let self else { return }
                self.notePlaybackTick(
                    trackKey: position.track.key,
                    timestamp: position.timestamp,
                    at: self.now()
                )
            }
            .store(in: &cancellables)

        notificationCenter
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.applicationDidBecomeActive()
            }
            .store(in: &cancellables)
    }

    // MARK: - Sinks

    private func traceLine(_ line: String) {
        guard diagnosticsEnabled() else { return }
        fileLog("[AUDIOPOS-TRACE] " + line)
    }

    /// `internal` + an injectable `emit` so a test can assert exactly what
    /// leaves the device; the data-minimisation claim is otherwise unpinned.
    static func crashlyticsSaveReport(
        _ verdict: PositionSaveVerdict,
        context: PositionTraceContext,
        emit: FleetEventEmitting = { code, summary, metadata in
            TPPErrorLogger.logError(withCode: code, summary: summary, metadata: metadata)
        }
    ) {
        // Only the finding reaches the fleet. `.saving` is the healthy case,
        // and `.noPlayback` / `.playbackStale` mean the instrument has nothing
        // to say — reporting those would bury the signal under every paused
        // session in the install base.
        //
        // `.tickGap` DOES reach the fleet, under its own code. It is not a
        // health claim and not a dry finding — it is the instrument reporting
        // that it could not see. Collapsing it into 404 would inflate the dry
        // count with sessions that were merely paused; collapsing it into
        // `.saving` would hide the locked-and-stalled case entirely. Round
        // three of this change already lost 405 to exactly that kind of
        // collapse, so each signal keeps its own code.
        //
        // Both findings carry the gap counters. A `.tickGap` without them is
        // an ambiguity the fleet cannot resolve, and a `.dry` is worth more
        // when it can be read against how choppy that session's tick stream
        // was. Counts of the device's own behaviour — no book, no title, no
        // patron.
        let shared: [String: Any] = [
            // The state seen by the last PLAYBACK TICK; see notePlaybackTick.
            "applicationStateAtLastTick": context.applicationStateAtLastTick,
            "tickGapCount": context.tickGapCount,
            "longestTickGapSeconds": context.longestTickGap,
            "clockRegressionCount": context.clockRegressionCount,
            "ticket": "PP-4963"
        ]
        switch verdict {
        case let .dry(seconds):
            emit(
                .audiobookPositionSaveDry,
                "Position saves dry while playback was live (PP-4963)",
                shared.merging(["drySeconds": seconds]) { _, new in new }
            )
        case let .tickGap(seconds):
            emit(
                .audiobookPositionTickGap,
                "Playback tick stream went quiet; save health unknown (PP-4963)",
                shared.merging(["gapSeconds": seconds]) { _, new in new }
            )
        case let .clockRegressed(by):
            emit(
                .audiobookPositionClockRegressed,
                "Device clock moved backwards under a trace session (PP-4963)",
                shared.merging(["regressedBySeconds": by]) { _, new in new }
            )
        case .noPlayback, .playbackStale, .saving:
            return
        }
    }

    /// `internal` for the same reason as `crashlyticsSaveReport`.
    static func crashlyticsGapReport(
        _ verdict: PositionRestoreGapVerdict,
        emit: FleetEventEmitting = { code, summary, metadata in
            TPPErrorLogger.logError(withCode: code, summary: summary, metadata: metadata)
        }
    ) {
        // `.behind` is the patron complaint. `.markerUnresolvable` is reported
        // too: it means a position we recorded as live could not be located in
        // the manifest we later loaded, which is its own defect and must not be
        // silently read as agreement.
        let summary: String
        let metadata: [String: Any]
        switch verdict {
        case let .behind(seconds):
            summary = "Restored behind last live position (PP-4963)"
            metadata = ["behindSeconds": seconds, "ticket": "PP-4963"]
        case let .markerUnresolvable(trackKey):
            summary = "Last-live marker not present in loaded manifest (PP-4963)"
            metadata = ["trackKeyLength": trackKey.count, "ticket": "PP-4963"]
        case .noMarker, .markerForDifferentBook, .aligned, .ahead:
            return
        }
        emit(.audiobookPositionRestoreGap, summary, metadata)
    }

    private static func applicationStateName() -> String {
        // `applicationState` is main-actor state; the recorder is called from
        // the player's thread, so read it only when already on main and report
        // "unknown" otherwise rather than hopping (which would reorder the
        // trace) or blocking.
        guard Thread.isMainThread else { return "unknown" }
        return MainActor.assumeIsolated {
            switch UIApplication.shared.applicationState {
            case .active: return "active"
            case .inactive: return "inactive"
            case .background: return "background"
            @unknown default: return "unknown"
            }
        }
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
