//
//  AudiobookPositionTraceRecorder.swift
//  Palace
//
//  PP-4963: the live half of the position instrumentation (decisions are in
//  `AudiobookPositionTrace.swift`). Crashlytics receives only findings, with a
//  duration and app state but no book, title, or patron identity. The per-book
//  file trace and the last-live marker store are gated on
//  `DebugSettings.isAudiobookPositionTraceEnabled` (default off): the trace
//  writes on every save, and the marker is patron data kept outside the
//  registry's deletion lifecycle. With the switch off, code 405 cannot fire.
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
/// Not the book registry, so a diagnostic cannot change where a book opens.
///
/// Reads and writes are gated on the diagnostics switch because a marker is
/// patron data with no purge or expiry. `purgeAll` is not gated: it runs from
/// the switch's setter after the switch is already false.
///
/// `@unchecked Sendable`: holds only a thread-safe `UserDefaults` and a
/// `@Sendable` closure; used from the player's thread and main.
struct UserDefaultsLastLivePositionMarkerStore: LastLivePositionMarkerStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let diagnosticsEnabled: @Sendable () -> Bool
    fileprivate static let keyPrefix = "audiobook.lastLivePosition."

    /// When `diagnosticsEnabled` is nil the gate reads
    /// `AudiobookPositionTraceRecorder.defaultDiagnosticsEnabled` against this
    /// store's own `defaults`, so there is one copy of that read.
    init(
        defaults: UserDefaults = .standard,
        diagnosticsEnabled: (@Sendable () -> Bool)? = nil
    ) {
        self.defaults = defaults
        // `UserDefaults` is documented thread-safe but not `Sendable`.
        nonisolated(unsafe) let gateDefaults = defaults
        self.diagnosticsEnabled = diagnosticsEnabled
            ?? { AudiobookPositionTraceRecorder.defaultDiagnosticsEnabled(defaults: gateDefaults) }
    }

    private func key(_ bookID: String) -> String { Self.keyPrefix + bookID }

    func marker(forBookID bookID: String) -> LastLivePositionMarker? {
        guard diagnosticsEnabled() else { return nil }
        guard let data = defaults.data(forKey: key(bookID)) else { return nil }
        return try? JSONDecoder().decode(LastLivePositionMarker.self, from: data)
    }

    func save(_ marker: LastLivePositionMarker) {
        guard diagnosticsEnabled() else { return }
        guard let data = try? JSONEncoder().encode(marker) else { return }
        defaults.set(data, forKey: key(marker.bookID))
    }

    /// Removes every stored marker. Called when the trace is switched off;
    /// Developer Settings is reachable in App Store builds, and nothing else
    /// purges these keys.
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
/// Position arithmetic, kept with the rest of the position trace.
enum AudiobookPositionOffsets {

    /// Maps a track key and timestamp to an offset in seconds from the start
    /// of the book, or nil when the loaded manifest contains no such track.
    ///
    /// Nil (not a best guess) lets the policy report `.markerUnresolvable`.
    /// Uses the toolkit's `TrackPosition` subtraction, which sums intervening
    /// track durations across boundaries.
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
/// `@unchecked Sendable` with an `NSLock` rather than `@MainActor`: ticks arrive
/// ~4×/s from the player's thread, so actor hops would cost a `Task` per tick.
/// Mutable state is touched only under `lock`, except `cancellables`, which is
/// written once during construction before any tick or save arrives.
final class AudiobookPositionTraceRecorder: @unchecked Sendable {

    /// How often the last-live marker is rewritten. A minute is far finer than
    /// the gaps patrons report.
    static let markerWriteInterval: TimeInterval = 60

    /// The one tick-freshness value in the system. A gap larger than this ends
    /// a stretch here, and the same constant decides staleness in
    /// `PositionSaveDryPolicy.evaluate`.
    ///
    /// Shared deliberately so the recorder's stretch boundary and the policy's
    /// staleness cannot drift apart.
    static let tickFreshnessWindow: TimeInterval = PositionSaveDryPolicy.defaultTickFreshness

    /// Serial and utility-QoS: trace writes must stay ordered relative to each
    /// other, and must never contend with playback or the save path.
    private static let fileLogQueue = DispatchQueue(
        label: "org.thepalaceproject.audiobook-position-trace",
        qos: .utility
    )

    /// How the shipped recorder decides whether the local trace is on.
    ///
    /// The single copy of this read, used by the init default and tests.
    static func defaultDiagnosticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        DebugSettings(defaults: defaults).isAudiobookPositionTraceEnabled
    }

    private let bookID: String
    private let markerStore: LastLivePositionMarkerStoring
    private let diagnosticsEnabled: () -> Bool
    private let reportSaveVerdict: (PositionSaveVerdict, PositionTraceContext) -> Void
    private let reportGapVerdict: (PositionRestoreGapVerdict) -> Void
    private let fileLog: (String) -> Void
    private let now: () -> Date

    private let lock = NSLock()
    /// The current stretch of playback, or nil before the first tick.
    private var stretch: PlaybackStretch?
    private var lastMarkerWriteAt: Date = .distantPast
    /// App state as seen by the most recent playback tick. See `notePlaybackTick`.
    private var lastObservedAppState: String = "unknown"
    /// How many times the tick stream went quiet long enough to open a new
    /// stretch, and the worst such gap; aggregated to separate pauses from
    /// stalls across the fleet.
    private var tickGapCount: Int = 0
    private var clockRegressionCount: Int = 0
    /// Whether the last tick was already behind the reference, so one clock
    /// step counts once rather than once per tick.
    private var inClockRegression = false
    private var longestTickGap: TimeInterval = 0

    private var cancellables = Set<AnyCancellable>()

    /// `defaults` pins the default marker store and diagnostics gate to one
    /// domain. They are built in the body because a default argument cannot
    /// read another parameter.
    init(
        bookID: String,
        defaults: UserDefaults = .standard,
        markerStore: LastLivePositionMarkerStoring? = nil,
        diagnosticsEnabled: (() -> Bool)? = nil,
        reportSaveVerdict: ((PositionSaveVerdict, PositionTraceContext) -> Void)? = nil,
        reportGapVerdict: ((PositionRestoreGapVerdict) -> Void)? = nil,
        fileLog: ((String) -> Void)? = nil,
        emitFleetEvent: FleetEventEmitting? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.bookID = bookID
        self.markerStore = markerStore
            ?? UserDefaultsLastLivePositionMarkerStore(defaults: defaults)
        self.diagnosticsEnabled = diagnosticsEnabled
            ?? { AudiobookPositionTraceRecorder.defaultDiagnosticsEnabled(defaults: defaults) }
        // The error code is part of the seam so 404 and 405 stay distinct.
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
            // Off the main actor (the `noteSave` callers' thread):
            // `AudiobookFileLogger.logEvent` does synchronous disk I/O, which
            // would slow the save path the trace is measuring. Serial, so lines
            // stay ordered.
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
        // A save belongs to the stretch it happened in; with no stretch the
        // verdict is `.noPlayback` regardless.
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

        // Gate before the interpolation, which is evaluated at the call site
        // and allocates a date formatter.
        guard diagnosticsEnabled() else { return }
        traceLine("save at=\(Self.stamp(date)) state=\(state)")
    }

    /// Called from `player.positionPublisher` — AVPlayer's periodic time
    /// observer, driven by the playback clock. This is the signal that keeps
    /// arriving while the screen is locked, and the reason the recorder can
    /// tell "saves stopped" from "playback stopped".
    func notePlaybackTick(trackKey: String, timestamp: Double, at date: Date) {
        // Captured on the tick; at foreground return it is always `.active`.
        let state = Self.applicationStateName()

        lock.lock()
        // A gap longer than the freshness window starts a new stretch, dropping
        // the previous save. The gap is recorded on the stretch because it may
        // be a pause or a stall, and the policy must not claim health for it.
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
                // Never backwards: an out-of-order tick or a wall-clock step
                // back would otherwise manufacture a spurious `.tickGap`. The
                // clamp is counted; a sustained step leaves the reference ahead
                // of now, which `PositionSaveDryPolicy` declines to measure.
                lastTickAt: max(current.lastTickAt, date),
                lastSaveAt: current.lastSaveAt,
                precededByGap: current.precededByGap
            )
        }
        // Snapshotted under the lock for the trace line below.
        let boundaryGap = isResume ? gap : nil
        let gapCountSoFar = tickGapCount
        let longestGapSoFar = longestTickGap
        lastObservedAppState = state
        let shouldWriteMarker = date.timeIntervalSince(lastMarkerWriteAt) >= Self.markerWriteInterval
        if shouldWriteMarker {
            lastMarkerWriteAt = date
        }
        lock.unlock()

        // Log stretch boundaries so a trace can tell a pause from a stall.
        if let boundaryGap {
            // Through `traceLine` so the line carries the `[AUDIOPOS-TRACE]`
            // prefix the log is filtered on.
            traceLine("stretch boundary after \(String(format: "%.1f", boundaryGap))s "
                      + "without a tick (gap #\(gapCountSoFar), "
                      + "longest \(String(format: "%.1f", longestGapSoFar))s)")
        }

        guard shouldWriteMarker else { return }

        // The marker is patron data, so it is persisted only while the trace is
        // on. Code 405 therefore reports only during trace runs; 404 stays
        // fleet-wide.
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
    /// Takes the `Player` so the liveness signal is always
    /// `player.positionPublisher`, whose source is the playback clock rather
    /// than the runloop timers under suspicion. It still delivers on the main
    /// queue, so it does not survive a wedged main thread.
    ///
    /// `@MainActor` because the toolkit's `Player` is; only the subscription is
    /// isolated.
    /// - Parameter notificationCenter: injectable so a test can drive the
    ///   subscription without a global `didBecomeActiveNotification` post.
    @MainActor
    func observe(player: Player, notificationCenter: NotificationCenter = .default) {
        observe(positionPublisher: player.positionPublisher,
                notificationCenter: notificationCenter)
    }

    /// The publisher-taking form, so a test can drive a liveness signal it
    /// cannot get a real `Player` to emit — `OpenAccessPlayer.positionSubject`
    /// is `private`. Production goes through `observe(player:)`.
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
        guard let payload = saveReportPayload(for: verdict, context: context) else { return }
        emit(payload.code, payload.summary, payload.metadata)
    }

    /// The exact event a save verdict puts on the wire, or nil when the verdict
    /// is not a finding.
    ///
    /// Separate from the emit so `AudiobookPositionTraceReportTests` can pin
    /// the exact key set, which is the privacy guarantee.
    static func saveReportPayload(
        for verdict: PositionSaveVerdict,
        context: PositionTraceContext
    ) -> (code: TPPErrorCode, summary: String, metadata: [String: Any])? {
        // Only findings reach the fleet; `.saving`, `.noPlayback` and
        // `.playbackStale` are not reported. `.tickGap` has its own code so it
        // neither inflates the dry count nor hides a stall. Findings carry the
        // gap counters (no book, title, or patron data).
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
            return (
                .audiobookPositionSaveDry,
                "Position saves dry while playback was live (PP-4963)",
                shared.merging(["drySeconds": seconds]) { _, new in new }
            )
        case let .tickGap(seconds):
            return (
                .audiobookPositionTickGap,
                "Playback tick stream went quiet; save health unknown (PP-4963)",
                shared.merging(["gapSeconds": seconds]) { _, new in new }
            )
        case let .clockRegressed(by):
            return (
                .audiobookPositionClockRegressed,
                "Device clock moved backwards under a trace session (PP-4963)",
                shared.merging(["regressedBySeconds": by]) { _, new in new }
            )
        case .noPlayback, .playbackStale, .saving:
            return nil
        }
    }

    /// `internal` for the same reason as `crashlyticsSaveReport`.
    static func crashlyticsGapReport(
        _ verdict: PositionRestoreGapVerdict,
        emit: FleetEventEmitting = { code, summary, metadata in
            TPPErrorLogger.logError(withCode: code, summary: summary, metadata: metadata)
        }
    ) {
        guard let payload = gapReportPayload(for: verdict) else { return }
        emit(payload.code, payload.summary, payload.metadata)
    }

    /// The exact event a restore-gap verdict puts on the wire, or nil when the
    /// verdict is not a finding. See `saveReportPayload(for:context:)` for why
    /// this is separated from the emit.
    ///
    /// `.markerUnresolvable` carries the track key's LENGTH and never the key
    /// itself: a track key is often the chapter title, which is book identity.
    static func gapReportPayload(
        for verdict: PositionRestoreGapVerdict
    ) -> (code: TPPErrorCode, summary: String, metadata: [String: Any])? {
        // `.markerUnresolvable` is reported too: a recorded position missing
        // from the later manifest is its own defect.
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
            return nil
        }
        return (.audiobookPositionRestoreGap, summary, metadata)
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
