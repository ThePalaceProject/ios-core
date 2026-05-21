//
//  NowPlayingCoordinator.swift
//  Palace
//
//  Coordinates all updates to MPNowPlayingInfoCenter.
//  Eliminates race conditions by providing a single update path with debouncing.
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
        /// Minimum interval between Now Playing updates (debounce) in the
        /// `.active` state. Background writes bypass debounce entirely.
        static let updateDebounceInterval: TimeInterval = 0.3

        /// HelpSpot 17865 — if the writer was dry for longer than this while
        /// `isPlaying` was true, log to Crashlytics on foreground return.
        /// Tuned just above the toolkit's `.background` 15s cadence with
        /// enough slack for one missed tick.
        static let dryStreamThreshold: TimeInterval = 30.0
    }

    // MARK: - Properties

    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()

    private var currentInfo: [String: Any] = [:]
    private var currentArtwork: MPMediaItemArtwork?
    private var lastUpdateTime: Date = .distantPast
    private var lastIsPlaying: Bool = false
    private var pendingUpdate: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

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
        now: @escaping () -> Date = { Date() }
    ) {
        self.applicationStateProvider = applicationStateProvider
        self.dryStreamLogger = dryStreamLogger
        self.now = now
        Log.info(#file, "NowPlayingCoordinator initialized")

        // HelpSpot 17865 — self-subscribe to foreground notification so the
        // dry-stream guard fires without coupling AudiobookSessionManager.
        // Tests drive the guard via `applicationDidBecomeActive()` directly
        // so they don't depend on UIApplication notification timing.
        foregroundObserver = NotificationCenter.default.addObserver(
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
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        Log.info(#file, "NowPlayingCoordinator deinitialized")
    }

    // MARK: - Public API

    /// Updates Now Playing info with all metadata.
    /// This is the primary update method - handles debouncing automatically.
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

        // Apply update with debouncing
        applyUpdate(info, isPlaying: isPlaying)
    }

    /// Updates only the playback state (playing/paused)
    /// Use this for quick state toggles without full info update
    public func setPlaybackState(playing: Bool) {
        var info = currentInfo

        // Update rate based on playing state
        let currentRate = info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double ?? 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? currentRate : 0.0

        // Apply immediately (no debounce for state changes)
        currentInfo = info
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
        nowPlayingInfoCenter.nowPlayingInfo = info

        Log.debug(#file, "Playback rate updated: \(rateValue)x")
    }

    /// Updates artwork separately from other info
    /// This prevents artwork updates from being debounced
    public func updateArtwork(_ image: UIImage?) {
        guard let image = image else {
            currentArtwork = nil
            return
        }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        currentArtwork = artwork

        var info = currentInfo
        info[MPMediaItemPropertyArtwork] = artwork
        currentInfo = info
        nowPlayingInfoCenter.nowPlayingInfo = info

        Log.debug(#file, "Artwork updated")
    }

    /// Clears all Now Playing info
    public func clearNowPlaying() {
        pendingUpdate?.cancel()
        pendingUpdate = nil

        currentInfo = [:]
        currentArtwork = nil
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
        // Cancel any pending update
        pendingUpdate?.cancel()

        // HelpSpot 17865 — when the app is NOT active, bypass debounce.
        // The main-queue scheduler stalls during suspend, so debounced
        // DispatchWorkItems can vanish — the coordinator's currentInfo and
        // the system MPNowPlayingInfoCenter diverge and the patron sees
        // stale info briefly on foreground return. In background the only
        // writers are the toolkit's 15s timer + remote-command handlers,
        // neither of which needs coalescing.
        if applicationStateProvider() != .active {
            performUpdate(info, isPlaying: isPlaying)
            return
        }

        // Check if we should debounce
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)

        if timeSinceLastUpdate >= Configuration.updateDebounceInterval {
            // Apply immediately
            performUpdate(info, isPlaying: isPlaying)
        } else {
            // Schedule debounced update.
            //
            // Cancel semantics — preserves prior `DispatchWorkItem.cancel()`
            // behavior across two race windows:
            //   1) Cancelled DURING the sleep — `Task.sleep` throws
            //      `CancellationError`; we swallow and `return`. Matches a
            //      cancelled work item simply not firing.
            //   2) Cancelled AFTER the sleep returns but BEFORE `performUpdate`
            //      — caught by the explicit `Task.isCancelled` guard. (Cancellation
            //      between `try await Task.sleep` returning and the next instruction
            //      executing is the narrow window the guard exists for.)
            let delay = Configuration.updateDebounceInterval - timeSinceLastUpdate
            let task = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.performUpdate(info, isPlaying: isPlaying)
            }
            pendingUpdate = task
        }
    }

    private func performUpdate(_ info: [String: Any], isPlaying: Bool) {
        currentInfo = info
        lastUpdateTime = Date()
        lastIsPlaying = isPlaying

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
