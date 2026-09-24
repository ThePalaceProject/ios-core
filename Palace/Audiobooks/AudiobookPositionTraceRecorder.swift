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
    private static let keyPrefix = "audiobook.lastLivePosition."

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
/// and reports are dispatched outside it.
final class AudiobookPositionTraceRecorder: @unchecked Sendable {

    /// How often the last-live marker is rewritten. `positionPublisher` emits
    /// ~4×/s; persisting at that rate would be pure write amplification, and a
    /// minute of granularity is far below the minutes-to-hours gap patrons
    /// report.
    static let markerWriteInterval: TimeInterval = 60

    private let bookID: String
    private let markerStore: LastLivePositionMarkerStoring
    private let diagnosticsEnabled: () -> Bool
    private let reportSaveVerdict: (PositionSaveVerdict) -> Void
    private let reportGapVerdict: (PositionRestoreGapVerdict) -> Void
    private let fileLog: (String) -> Void
    private let now: () -> Date

    private let lock = NSLock()
    private var sessionStartedAt: Date
    private var lastTickAt: Date?
    private var lastSaveAt: Date?
    private var lastMarkerWriteAt: Date = .distantPast

    private var cancellables = Set<AnyCancellable>()

    init(
        bookID: String,
        markerStore: LastLivePositionMarkerStoring = UserDefaultsLastLivePositionMarkerStore(),
        diagnosticsEnabled: @escaping () -> Bool = {
            DebugSettings().isAudiobookPositionTraceEnabled
        },
        reportSaveVerdict: ((PositionSaveVerdict) -> Void)? = nil,
        reportGapVerdict: ((PositionRestoreGapVerdict) -> Void)? = nil,
        fileLog: ((String) -> Void)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.bookID = bookID
        self.markerStore = markerStore
        self.diagnosticsEnabled = diagnosticsEnabled
        self.reportSaveVerdict = reportSaveVerdict ?? Self.crashlyticsSaveReport
        self.reportGapVerdict = reportGapVerdict ?? Self.crashlyticsGapReport
        self.fileLog = fileLog ?? { [bookID] line in
            AudiobookFileLogger.shared.logEvent(forBookId: bookID, event: line)
        }
        self.now = now
        self.sessionStartedAt = now()
    }

    // MARK: - Signals in

    /// Called after a position is written to the LOCAL registry — the write
    /// that decides whether the patron keeps their place. The remote annotation
    /// post is a separate defect and is deliberately not what this measures.
    func noteSave(at date: Date) {
        lock.lock()
        lastSaveAt = date
        lock.unlock()

        traceLine("save at=\(Self.stamp(date)) state=\(Self.applicationStateName())")
    }

    /// Called from `player.positionPublisher` — AVPlayer's periodic time
    /// observer, driven by the playback clock. This is the signal that keeps
    /// arriving while the screen is locked, and the reason the recorder can
    /// tell "saves stopped" from "playback stopped".
    func notePlaybackTick(trackKey: String, timestamp: Double, at date: Date) {
        lock.lock()
        lastTickAt = date
        let shouldWriteMarker = date.timeIntervalSince(lastMarkerWriteAt) >= Self.markerWriteInterval
        if shouldWriteMarker {
            lastMarkerWriteAt = date
        }
        lock.unlock()

        guard shouldWriteMarker else { return }

        markerStore.save(LastLivePositionMarker(
            bookID: bookID,
            trackKey: trackKey,
            timestamp: timestamp,
            recordedAt: date
        ))
        traceLine(
            "live track=\(trackKey) t=\(String(format: "%.1f", timestamp)) "
            + "state=\(Self.applicationStateName())"
        )
    }

    // MARK: - Verdicts out

    /// Evaluated on foreground return, the one moment we can compare the two
    /// clocks and still be running.
    func applicationDidBecomeActive() {
        lock.lock()
        let verdict = PositionSaveDryPolicy.evaluate(
            now: now(),
            sessionStartedAt: sessionStartedAt,
            lastTickAt: lastTickAt,
            lastSaveAt: lastSaveAt
        )
        lock.unlock()

        traceLine("verdict \(verdict)")
        reportSaveVerdict(verdict)
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
    func observe(positionPublisher: AnyPublisher<TrackPosition, Never>) {
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

        NotificationCenter.default
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

    private static func crashlyticsSaveReport(_ verdict: PositionSaveVerdict) {
        // Only the finding reaches the fleet. `.saving` is the healthy case,
        // and `.noPlayback` / `.playbackStale` mean the instrument has nothing
        // to say — reporting those would bury the signal under every paused
        // session in the install base.
        guard case let .dry(seconds) = verdict else { return }
        TPPErrorLogger.logError(
            withCode: .audiobookPositionSaveDry,
            summary: "Position saves dry while playback was live (PP-4963)",
            metadata: [
                "drySeconds": seconds,
                "applicationState": applicationStateName(),
                "ticket": "PP-4963"
            ]
        )
    }

    private static func crashlyticsGapReport(_ verdict: PositionRestoreGapVerdict) {
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
        TPPErrorLogger.logError(
            withCode: .audiobookPositionRestoreGap,
            summary: summary,
            metadata: metadata
        )
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
