//
//  NowPlayingCoordinator.swift
//  Palace
//
//  Coordinates all updates to MPNowPlayingInfoCenter.
//  The only writer of Now Playing info in the app (PP-5504).
//
//  Note: Remote commands (play/pause/skip) are handled by the toolkit's MediaControlPublisher.
//  This coordinator only manages Now Playing INFO, not commands.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import MediaPlayer
import PalaceAudiobookToolkit
import UIKit
import PalaceLogging
import PalaceBookRegistry

// MARK: - NowPlayingInfoCenterWriting

/// The two `MPNowPlayingInfoCenter` properties the coordinator writes.
/// Injected so tests count writes without touching the shared system center.
protocol NowPlayingInfoCenterWriting: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoCenterWriting {}

// MARK: - NowPlayingCoordinator

/// Coordinates all updates to MPNowPlayingInfoCenter.
/// This is the ONLY class that should update Now Playing info to prevent race conditions.
///
/// Note: Remote commands are handled by the toolkit's MediaControlPublisher, not here.
/// This avoids conflicts where multiple handlers try to manage the same commands.
@MainActor
public final class NowPlayingCoordinator {

    // MARK: - Configuration

    private enum Configuration {
        /// HelpSpot 17865 — if the writer was dry for longer than this while
        /// `isPlaying` was true, log to Crashlytics on foreground return.
        /// Tuned just above the toolkit's `.background` 15s cadence with
        /// enough slack for one missed tick.
        static let dryStreamThreshold: TimeInterval = 30.0

        /// Longest gap between writes while nothing has changed.
        /// Well under `dryStreamThreshold`, so a healthy stream never looks dry.
        static let backgroundKeepAliveInterval: TimeInterval = 10.0

        /// An elapsed time further than this from the extrapolated
        /// value is a seek or skip, not timer jitter, and is written at once.
        static let seekTolerance: TimeInterval = 1.0
    }

    /// Fields MediaPlayer cannot extrapolate; a change to any of them is
    /// always written.
    private static let nonExtrapolatedKeys = [
        MPMediaItemPropertyTitle,
        MPMediaItemPropertyArtist,
        MPMediaItemPropertyAlbumTitle,
        MPMediaItemPropertyPlaybackDuration,
        MPNowPlayingInfoPropertyPlaybackRate,
        MPNowPlayingInfoPropertyDefaultPlaybackRate
    ]

    // MARK: - Properties

    private let nowPlayingInfoCenter: NowPlayingInfoCenterWriting

    private var currentInfo: [String: Any] = [:]
    private var currentArtwork: MPMediaItemArtwork?
    private var lastUpdateTime: Date = .distantPast
    private var lastIsPlaying: Bool = false
    /// When the last write landed (injected clock), and the elapsed time and
    /// rate it carried, so background ticks can be checked against the
    /// position MediaPlayer extrapolates on its own.
    private var lastWrite: (at: Date, elapsed: TimeInterval, rate: Double)?
    /// Foreground-notification observer token. Held in a nonisolated
    /// `@unchecked Sendable` box so the nonisolated `deinit` can remove it
    /// WITHOUT reading a `@MainActor`-isolated stored property (which
    /// `complete` mode rejects, and `MainActor.assumeIsolated` is banned in
    /// deinit).
    private let foregroundObserverBox = ObserverTokenBox()

    /// Injectable seam for `UIApplication.shared.applicationState`. Tests
    /// flip this to drive the background / foreground branches without
    /// touching the real shared instance.
    private let applicationStateProvider: () -> UIApplication.State

    /// Injectable seam for `TPPErrorLogger.logError`. Tests verify the
    /// dry-stream guard fires by intercepting calls here. Defaults to the
    /// real Crashlytics path.
    private let dryStreamLogger: (_ summary: String, _ metadata: [String: Any]?) -> Void

    /// Injectable clock for the dry-stream guard's freshness check. Tests
    /// pin staleness at exact-boundary values that would otherwise jitter
    /// against wall time. Defaults to `Date()`.
    private let now: () -> Date

    // MARK: - Initialization

    public convenience init() {
        self.init(
            applicationStateProvider: { UIApplication.shared.applicationState },
            dryStreamLogger: { summary, metadata in
                TPPErrorLogger.logError(
                    withCode: .audiobookNowPlayingDry,
                    summary: summary,
                    metadata: metadata
                )
            },
            now: { Date() }
        )
    }

    /// Test-facing initializer. Production code should use the no-arg
    /// `init()` above so the real `UIApplication.shared` + `TPPErrorLogger`
    /// are wired.
    init(
        applicationStateProvider: @escaping () -> UIApplication.State,
        dryStreamLogger: @escaping (_ summary: String, _ metadata: [String: Any]?) -> Void,
        now: @escaping () -> Date = { Date() },
        infoCenter: NowPlayingInfoCenterWriting = MPNowPlayingInfoCenter.default()
    ) {
        self.nowPlayingInfoCenter = infoCenter
        self.applicationStateProvider = applicationStateProvider
        self.dryStreamLogger = dryStreamLogger
        self.now = now
        Log.info(#file, "NowPlayingCoordinator initialized")

        // HelpSpot 17865 — self-subscribe to foreground notification so the
        // dry-stream guard fires without coupling AudiobookSessionManager.
        // Tests drive the guard via `applicationDidBecomeActive()` directly
        // so they don't depend on UIApplication notification timing.
        foregroundObserverBox.token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkForDryStream()
            }
        }
    }

    deinit {
        foregroundObserverBox.removeObserver()
        Log.info(#file, "NowPlayingCoordinator deinitialized")
    }

    // MARK: - Public API

    /// Updates Now Playing info with all metadata.
    /// This is the primary update method. A tick whose elapsed time MediaPlayer
    /// extrapolates on its own is not written.
    public func updateNowPlaying(
        title: String,
        artist: String?,
        album: String?,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        playbackRate: PlaybackRate
    ) {
        // Build the info dictionary
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title

        if let artist = artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        // Ensure valid timing values
        let safeElapsed = max(0, min(elapsed, duration))
        let safeDuration = max(1.0, abs(duration))

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = safeElapsed
        info[MPMediaItemPropertyPlaybackDuration] = safeDuration

        // Set playback rate
        let rateValue = Double(PlaybackRate.convert(rate: playbackRate))
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rateValue
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rateValue : 0.0

        // Set media type for CarPlay
        info[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue

        // Preserve artwork if set
        if let artwork = currentArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        applyUpdate(info, isPlaying: isPlaying)
    }

    /// Updates only the playback state (playing/paused)
    /// Use this for quick state toggles without full info update
    public func setPlaybackState(playing: Bool) {
        var info = currentInfo

        // Update rate based on playing state
        let currentRate = info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double ?? 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? currentRate : 0.0

        currentInfo = info
        lastIsPlaying = playing
        recordWrite(info)
        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = playing ? .playing : .paused

        Log.debug(#file, "Playback state set: \(playing ? "playing" : "paused")")
    }

    /// Updates playback rate
    public func updatePlaybackRate(_ rate: PlaybackRate) {
        var info = currentInfo
        let rateValue = Double(PlaybackRate.convert(rate: rate))

        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rateValue

        // If playing, also update current rate
        let isPlaying = nowPlayingInfoCenter.playbackState == .playing
        if isPlaying {
            info[MPNowPlayingInfoPropertyPlaybackRate] = rateValue
        }

        currentInfo = info
        recordWrite(info)
        nowPlayingInfoCenter.nowPlayingInfo = info

        Log.debug(#file, "Playback rate updated: \(rateValue)x")
    }

    /// Updates artwork separately from other info, and writes it at once.
    public func updateArtwork(_ image: UIImage?) {
        guard let image = image else {
            currentArtwork = nil
            return
        }

        // MediaPlayer invokes this request handler OFF the main actor (it
        // serializes the artwork on a background queue via
        // `-[MPMediaItemArtwork jpegDataWithSize:]` when building the
        // Now-Playing / lock-screen info). Under the Swift 6 language mode the
        // closure would otherwise inherit this type's `@MainActor` isolation
        // and trip `dispatch_assert_queue` → crash on every audiobook open
        // (regression from the SWIFT_VERSION 5→6 flip, #1199). `@Sendable`
        // strips the inherited isolation so the handler is callable on
        // MediaPlayer's queue; `nonisolated(unsafe)` opts the captured image
        // out of Sendable checking (reading a `UIImage` for rasterization is
        // thread-safe here — it is created once and never mutated).
        nonisolated(unsafe) let capturedImage = image
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in capturedImage }
        currentArtwork = artwork

        var info = currentInfo
        info[MPMediaItemPropertyArtwork] = artwork
        currentInfo = info
        recordWrite(info)
        nowPlayingInfoCenter.nowPlayingInfo = info

        Log.debug(#file, "Artwork updated")
    }

    /// Clears all Now Playing info
    public func clearNowPlaying() {
        currentInfo = [:]
        currentArtwork = nil
        lastWrite = nil
        nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingInfoCenter.playbackState = .stopped

        Log.info(#file, "Now Playing cleared")
    }

    /// Hook the lifecycle owner (AudiobookSessionManager) into the
    /// dry-stream guard. Call when `UIApplication.didBecomeActiveNotification`
    /// fires. HelpSpot 17865 instrumentation.
    public func applicationDidBecomeActive() {
        checkForDryStream()
    }

    // MARK: - Private Methods

    private func applyUpdate(_ info: [String: Any], isPlaying: Bool) {
        // Playback ticks arrive four times a second. MediaPlayer advances the
        // elapsed time from the last written time and rate, so write only a
        // change it cannot extrapolate (PP-4970, PP-5504). A needed write goes
        // out at once in every app state: a delayed write can be lost while
        // the app is suspended (HelpSpot 17865), and in the foreground it
        // would show a seek or chapter change late on CarPlay.
        guard writeIsNeeded(info, isPlaying: isPlaying) else {
            // Keep the latest values so a direct write (pause, rate,
            // artwork) carries the current position, not the last written one.
            currentInfo = info
            return
        }
        performUpdate(info, isPlaying: isPlaying)
    }

    /// MediaPlayer advances the lock-screen time from the last written elapsed
    /// time and rate, so a write is needed only when something it cannot
    /// extrapolate has changed, or the keep-alive interval has passed.
    private func writeIsNeeded(_ info: [String: Any], isPlaying: Bool) -> Bool {
        guard let last = lastWrite, isPlaying == lastIsPlaying else { return true }
        for key in Self.nonExtrapolatedKeys where info[key] as? AnyHashable != currentInfo[key] as? AnyHashable {
            return true
        }
        let sinceLastWrite = now().timeIntervalSince(last.at)
        if sinceLastWrite >= Configuration.backgroundKeepAliveInterval {
            return true
        }
        let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        let extrapolated = last.elapsed + sinceLastWrite * last.rate
        return abs(elapsed - extrapolated) > Configuration.seekTolerance
    }

    /// Every write to the system center sets the base the tick skip
    /// extrapolates from.
    private func recordWrite(_ info: [String: Any]) {
        lastWrite = (
            at: now(),
            elapsed: info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0,
            rate: info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
        )
    }

    private func performUpdate(_ info: [String: Any], isPlaying: Bool) {
        currentInfo = info
        lastUpdateTime = now()
        lastIsPlaying = isPlaying
        recordWrite(info)

        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = isPlaying ? .playing : .paused

        let title = info[MPMediaItemPropertyTitle] as? String ?? "Unknown"
        let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0

        Log.debug(#file, "Now Playing updated - title: '\(title)', elapsed: \(Int(elapsed))s/\(Int(duration))s, playing: \(isPlaying)")
    }

    /// HelpSpot 17865 instrumentation — on foreground return, if the writer
    /// was dry for >30s while `isPlaying` was true, the toolkit's timer is
    /// likely paused or its position publisher is stuck. Log to Crashlytics
    /// so the next regression of the same shape lands in our crash console,
    /// not a HelpSpot ticket.
    private func checkForDryStream() {
        guard lastIsPlaying else { return }

        let secondsSinceLastUpdate = now().timeIntervalSince(lastUpdateTime)
        guard secondsSinceLastUpdate > Configuration.dryStreamThreshold else { return }

        dryStreamLogger(
            "NowPlayingCoordinator dry while isPlaying — possible toolkit timer regression",
            [
                "secondsSinceLastUpdate": secondsSinceLastUpdate,
                "applicationState": applicationStateProvider().rawValue,
                "helpspotTicket": "17865"
            ]
        )
    }

    // MARK: - Test-only seams

    /// Test-only: back-date `lastUpdateTime` to simulate a dry stream.
    /// Internal so tests in the same module can use it via `@testable import`;
    /// not part of the public API.
    func _test_setLastUpdateTime(_ date: Date) {
        lastUpdateTime = date
    }

    /// Test-only: set `lastIsPlaying` to drive the dry-stream guard's
    /// gating condition.
    func _test_setLastIsPlaying(_ playing: Bool) {
        lastIsPlaying = playing
    }
}

/// Nonisolated `Sendable` holder for the foreground-notification observer
/// token. The `@MainActor`-isolated `NowPlayingCoordinator` cannot
/// read an isolated stored property from its nonisolated `deinit`, so the
/// token lives here instead. `token` is written exactly once (right after
/// `addObserver` returns in `init`) and read only by `removeObserver()` —
/// write-once-then-read confinement, hence `@unchecked Sendable`.
private final class ObserverTokenBox: @unchecked Sendable {
    var token: NSObjectProtocol?
    func removeObserver() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
