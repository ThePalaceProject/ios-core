//
//  PlaybackBootstrapper.swift
//  Palace
//
//  Ensures audio playback infrastructure is ready for CarPlay cold starts.
//  This class sets up AVAudioSession and MPRemoteCommandCenter handlers
//  BEFORE any book is opened, enabling remote controls to work immediately.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation
import MediaPlayer
import PalaceAudiobookToolkit
import PalaceLogging

// MARK: - PlaybackBootstrapper

/// Singleton that bootstraps audio playback infrastructure for CarPlay cold starts.
///
/// On iOS, CarPlay can launch the app in the background (cold start) without any UI.
/// For remote controls (play/pause/skip) to work, we must:
/// 1. Configure AVAudioSession early
/// 2. Register MPRemoteCommandCenter handlers BEFORE a book is opened
/// 3. Route commands to the active AudiobookManager when one exists
///
/// This class ensures these requirements are met, independent of UI lifecycle.
///
/// ## Usage
/// Call `ensureInitialized()` early in:
/// - `TPPAppDelegate.application(_:didFinishLaunchingWithOptions:)`
/// - `CarPlaySceneDelegate.templateApplicationScene(_:didConnect:)`
///
/// In production callers go through `AppContainer.production().playbackBootstrapper`;
/// in tests construct a fresh `PlaybackBootstrapper(appContainer:audiobookSessionProvider:)`
/// with a mock `audiobookSessionProvider` to avoid hitting the cached session.
///
/// ## Regression Test Plan
/// 1. Force-quit the Palace app on your phone
/// 2. Connect to CarPlay (car or Xcode simulator)
/// 3. Launch Palace from CarPlay
/// 4. Select an audiobook and play
/// 5. Verify: Play/Pause works via CarPlay buttons
/// 6. Verify: Skip forward/backward (30s) works
/// 7. Verify: Steering wheel media buttons work
/// 8. Lock phone screen during playback - verify controls still work
/// 9. Disconnect and reconnect CarPlay - verify no duplicate handlers
///
@MainActor
public final class PlaybackBootstrapper {

    // MARK: - State

    private var isInitialized = false
    private var commandTargets: [Any] = []
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let bookRegistry: TPPBookRegistryProvider
    /// Resolved-on-demand audiobook session. The bootstrapper is constructed
    /// at app launch — long before any audiobook is opened — and the session
    /// manager participates in cold-launch init, so taking the reference at
    /// construction time would risk an init-order race. Closure form lets
    /// tests inject a mock and lets the production closure resolve through
    /// `AppContainer.production().audiobookSession` lazily.
    private let audiobookSessionProvider: () -> AudiobookSessionManaging
    /// Off-main-safe read of "is an audiobook manager currently bound," used by
    /// the `@Sendable` remote-command handlers (which run on MediaRemote's
    /// BACKGROUND queue and therefore MUST NOT touch `@MainActor` state — that is
    /// the #1218 / #1199 crash class). Kept SEPARATE from
    /// `audiobookSessionProvider` (whose production closure reads the `@MainActor`
    /// `AppContainer.audiobookSession` and is thus main-only): this source reads
    /// the `nonisolated` `AudiobookSessionManager.hasActiveManagerSnapshot`
    /// mirror instead. `@Sendable` so it can be captured by the off-main handlers;
    /// tests inject a controllable `Bool` for deterministic gating.
    private let hasActiveManagerSnapshot: @Sendable () -> Bool
    /// Dispatches the deferred audio-session configuration off the synchronous
    /// launch path (see `ensureInitialized()`). Production hops to a background
    /// queue; tests inject an inline/capturing dispatcher to observe the
    /// deferral deterministically. Injecting this does NOT change the CarPlay
    /// re-run-on-playback paths, which call `configureAudioSession()` directly.
    private let launchAudioSessionDispatcher: (@escaping @Sendable () -> Void) -> Void

    // MARK: - Initialization

    /// Designated init — every dependency is explicit. The
    /// `launchAudioSessionDispatcher` default dispatches to a background utility
    /// queue so cold launch isn't charged the `setCategory` cost; it's a
    /// per-call default-argument literal (not a shared global) so the param type
    /// can stay non-`@Sendable` and let tests inject a capturing dispatcher.
    private init(
        bookRegistry: TPPBookRegistryProvider,
        audiobookSessionProvider: @escaping () -> AudiobookSessionManaging,
        hasActiveManagerSnapshot: @escaping @Sendable () -> Bool = { AudiobookSessionManager.hasActiveManagerSnapshot },
        launchAudioSessionDispatcher: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    ) {
        self.bookRegistry = bookRegistry
        self.audiobookSessionProvider = audiobookSessionProvider
        self.hasActiveManagerSnapshot = hasActiveManagerSnapshot
        self.launchAudioSessionDispatcher = launchAudioSessionDispatcher
        Log.info(#file, "🚀 PlaybackBootstrapper created - app launch context")

        // Log the launch context for debugging cold start issues
        let launchReason = determineLaunchContext()
        Log.info(#file, "🚀 Launch context: \(launchReason)")
    }

    /// AppContainer-friendly initializer for future call sites that thread
    /// the container down. Defaults the audiobook session provider to the
    /// `.shared` accessor since AppContainer doesn't currently hold the
    /// audiobook session manager.
    convenience init(
        appContainer: AppContainer,
        audiobookSessionProvider: @escaping () -> AudiobookSessionManaging,
        hasActiveManagerSnapshot: @escaping @Sendable () -> Bool = { AudiobookSessionManager.hasActiveManagerSnapshot },
        launchAudioSessionDispatcher: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    ) {
        self.init(
            bookRegistry: appContainer.bookRegistry,
            audiobookSessionProvider: audiobookSessionProvider,
            hasActiveManagerSnapshot: hasActiveManagerSnapshot,
            launchAudioSessionDispatcher: launchAudioSessionDispatcher
        )
    }

    /// Determines how the app was launched (for diagnostic logging)
    private func determineLaunchContext() -> String {
        var context: [String] = []

        // Check if app has any connected scenes
        let application = UIApplication.shared
        let connectedScenes = application.connectedScenes

        for scene in connectedScenes {
            switch scene.session.role {
            case .carTemplateApplication:
                context.append("CarPlay")
            case .windowApplication:
                context.append("MainApp")
            default:
                context.append("Other(\(scene.session.role.rawValue))")
            }
        }

        if context.isEmpty {
            context.append("NoScenesYet")
        }

        // Check if running in background
        if application.applicationState == .background {
            context.append("Background")
        }

        return context.joined(separator: ", ")
    }

    // MARK: - Public API

    /// Ensures playback infrastructure is ready.
    /// Safe to call multiple times - will only initialize once.
    ///
    /// Call this early in app lifecycle:
    /// - App launch (didFinishLaunchingWithOptions)
    /// - CarPlay scene connect
    ///
    /// ## Why This Matters for CarPlay Cold Start
    /// When CarPlay launches the app without the phone UI ever being shown:
    /// 1. Only CarPlaySceneDelegate receives lifecycle callbacks
    /// 2. No ViewControllers or SwiftUI views are created
    /// 3. Remote commands must work BEFORE any book is selected
    ///
    /// This method ensures MPRemoteCommandCenter is ready to receive commands
    /// even though there's no active playback yet. Commands received before
    /// a book is opened will return .noActionableNowPlayingItem, which is correct.
    public func ensureInitialized() {
        guard !isInitialized else {
            Log.debug(#file, "🚀 PlaybackBootstrapper.ensureInitialized() - already initialized")
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        Log.debug(#file, "🚀 PlaybackBootstrapper initializing audio infrastructure")

        // 1. Set up remote command handlers SYNCHRONOUSLY. CarPlay can cold-start
        //    the app with no UI, so MPRemoteCommandCenter handlers must be
        //    registered before the first transport command can arrive.
        setupRemoteCommands()

        // 2. Defer AVAudioSession category configuration off the synchronous launch
        //    path. This early — before any scene connects — `setCategory` routinely
        //    fails OSStatus -50 and is re-run later on scene-connect / first play
        //    (see `ensureInitializedForCarPlay` and `ensureAudioSessionActiveForPlayback`),
        //    so running it inline only charges cold launch the main-thread cost.
        launchAudioSessionDispatcher { [weak self] in
            self?.configureAudioSession()
        }

        // 3. Ensure AudiobookSessionManager exists so it can receive open
        //    requests from either phone UI or CarPlay bridge. Resolving the
        //    provider closure here forces lazy singleton init at the right
        //    point in app launch.
        _ = audiobookSessionProvider()

        isInitialized = true

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Log.info(#file, "🚀 PlaybackBootstrapper initialized in \(String(format: "%.1f", elapsed))ms")
    }

    /// Call when CarPlay connects to ensure audio session is active.
    /// This is the primary entry point for CarPlay cold starts.
    ///
    /// ## Idempotent Behavior
    /// Safe to call multiple times:
    /// - First call: Full initialization
    /// - Subsequent calls: Re-activates audio session and re-applies command config
    public func ensureInitializedForCarPlay() {
        Log.debug(#file, "🚀 PlaybackBootstrapper preparing for CarPlay")

        // CRITICAL: Load book registry from disk for CarPlay cold starts.
        // Constructing the registry inside AppContainer doesn't trigger a
        // disk load — we must explicitly call load() to read books from disk.
        (bookRegistry as? TPPBookRegistry)?.load()

        // Full initialization if not done yet
        ensureInitialized()

        // Re-activate audio session in case it was deactivated. Runs as a
        // detached MainActor task so the synchronous CarPlay `didConnect`
        // path is NOT blocked by the bounded retry/backoff — the deferral in
        // `.forgeos/intent/3.2.0-crash-triage.md` flagged a ~1s main-thread
        // block if this retried synchronously. WS-2 / Crashlytics d45f5aa9.
        Task { @MainActor [weak self] in
            await self?.activateAudioSessionWithRetry()
        }

        // Re-apply command configuration to ensure correctness after reconnect
        configureCommandSettings()

        Log.debug(#file, "🚀 PlaybackBootstrapper ready for CarPlay")
    }

    /// Ensure the audio session is configured AND active before a normal (phone)
    /// audiobook open issues `play()`.
    ///
    /// At cold launch `configureAudioSession()` can fail with OSStatus -50 ("no
    /// scenes yet"), and `setActive(true)` previously ran ONLY on CarPlay connect
    /// (`ensureInitializedForCarPlay`) or foreground re-entry — never on a plain
    /// first open. So the first `play()` of a freshly-opened audiobook was issued
    /// against an INACTIVE session and failed with AVError -11849 ("Operation
    /// Stopped"), recovering only on a retry/auto-reopen — the "slow to start"
    /// symptom (pre-existing; also reproduces on 3.1.0, so not a 3.2.0
    /// regression). By open time the scenes ARE connected, so re-running the
    /// category setup now succeeds, and we activate with the same bounded retry
    /// used for CarPlay. Idempotent and safe to call on every open; the activator
    /// skips activation when other audio is already playing. Fire-and-forget so
    /// the synchronous open path is never blocked by the backoff.
    // PUBLIC_INTENT: lifecycle entry point on the public PlaybackBootstrapper, matching the sibling `public` ensureInitialized()/ensureInitializedForCarPlay() bootstrap surface.
    public func ensureAudioSessionActiveForPlayback() {
        configureAudioSession()
        Task { @MainActor [weak self] in
            await self?.activateAudioSessionWithRetry()
        }
    }

    // MARK: - Audio Session

    // `nonisolated`: touches only the thread-safe `AVAudioSession.sharedInstance()`
    // and `Log` — no `@MainActor` `self` state — so `ensureInitialized()` can
    // dispatch it off-main via `launchAudioSessionDispatcher`, while the
    // synchronous re-run callers (`ensureAudioSessionActiveForPlayback`,
    // `ensureInitializedForCarPlay`) still invoke it directly. Body unchanged.
    nonisolated private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()

        do {
            // .playback category: continues in background
            // .spokenAudio mode: optimized for audiobooks, enables proper skip buttons
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetoothA2DP, .allowAirPlay]
            )

            Log.info(#file, "🔊 Audio session configured (category: playback, mode: spokenAudio)")
        } catch {
            // Error -50 (paramErr) can occur during early app launch before scenes connect.
            // This is expected and the session will be reconfigured when CarPlay connects.
            let nsError = error as NSError
            if nsError.code == -50 {
                Log.info(#file, "🔊 Audio session configuration deferred (early launch, no scenes yet) - will retry on CarPlay connect")
            } else {
                Log.error(#file, "🔊 Failed to configure audio session: \(error)")
            }
        }
    }

    /// Activates the audio session with a bounded async retry/backoff.
    ///
    /// CarPlay cold launch can transiently refuse activation (observed
    /// OSStatus 561015905, plus `-50` in the very-early window). Before WS-2
    /// a single refusal left the session inactive, so the toolkit's
    /// OpenAccessPlayer reported not-ready and the CarPlay play command hit
    /// `.playerNotReady` (Crashlytics d45f5aa9). The retry gives the session
    /// time to become active before play is issued. Async so the bounded
    /// backoff never blocks the MainActor `didConnect` path.
    private func activateAudioSessionWithRetry() async {
        let session = AVAudioSession.sharedInstance()
        let activator = AudioSessionActivator(
            isOtherAudioPlaying: { session.isOtherAudioPlaying },
            setActive: { try session.setActive(true) },
            sleep: { seconds in
                let nanos = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        )

        switch await activator.activate() {
        case .activated(let attempts):
            Log.debug(#file, "🔊 Audio session activated (attempts: \(attempts))")
        case .skippedOtherAudioPlaying:
            Log.debug(#file, "🔊 Audio session activation skipped — other audio playing")
        case .failed(let attempts, let code):
            Log.error(#file, "🔊 Failed to activate audio session after \(attempts) attempts (last OSStatus \(code))")
        }
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        // Clear any existing targets first
        removeAllTargets()

        // Configure which commands are enabled
        configureCommandSettings()

        // Add our targets
        addCommandTargets()

        Log.debug(#file, "🎮 Remote command handlers registered")
    }

    private func configureCommandSettings() {
        // Enable audiobook-specific commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        // PP-4712: reflect the patron's global skip-interval choices on the
        // lock-screen / CarPlay skip controls (default 30s each).
        let skipSettings = AudiobookSkipIntervalSettings()
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipSettings.forwardInterval)]
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipSettings.backInterval)]
        commandCenter.changePlaybackRateCommand.isEnabled = true

        // CRITICAL: Disable track navigation commands
        // Without this, CarPlay interprets skip as next/previous track
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false

        Log.debug(#file, "🎮 Command settings configured (skip intervals: fwd \(skipSettings.forwardInterval)s / back \(skipSettings.backInterval)s)")
    }

    private func addCommandTargets() {
        // Play command
        let playTarget = commandCenter.playCommand.addTarget { @Sendable [weak self] _ in
            Log.debug(#file, "🎮 ▶️ PLAY command received")
            return self?.handlePlay() ?? .noActionableNowPlayingItem
        }
        commandTargets.append(playTarget)

        // Pause command
        let pauseTarget = commandCenter.pauseCommand.addTarget { @Sendable [weak self] _ in
            Log.debug(#file, "🎮 ⏸️ PAUSE command received")
            return self?.handlePause() ?? .noActionableNowPlayingItem
        }
        commandTargets.append(pauseTarget)

        // Toggle play/pause (headphone button, steering wheel)
        let toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Log.debug(#file, "🎮 ⏯️ TOGGLE command received")
            return self?.handleTogglePlayPause() ?? .noActionableNowPlayingItem
        }
        commandTargets.append(toggleTarget)

        // Skip forward (30 seconds)
        let skipForwardTarget = commandCenter.skipForwardCommand.addTarget { @Sendable [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                Log.error(#file, "🎮 skipForward event cast failed")
                return .commandFailed
            }
            Log.debug(#file, "🎮 ⏩ SKIP FORWARD \(skipEvent.interval)s")
            return self?.handleSkipForward(interval: skipEvent.interval) ?? .noActionableNowPlayingItem
        }
        commandTargets.append(skipForwardTarget)

        // Skip backward (30 seconds)
        let skipBackwardTarget = commandCenter.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                Log.error(#file, "🎮 skipBackward event cast failed")
                return .commandFailed
            }
            Log.debug(#file, "🎮 ⏪ SKIP BACKWARD \(skipEvent.interval)s")
            return self?.handleSkipBackward(interval: skipEvent.interval) ?? .noActionableNowPlayingItem
        }
        commandTargets.append(skipBackwardTarget)

        // Change playback rate
        let rateTarget = commandCenter.changePlaybackRateCommand.addTarget { @Sendable [weak self] event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
                Log.error(#file, "🎮 changePlaybackRate event cast failed")
                return .commandFailed
            }
            Log.debug(#file, "🎮 🔄 PLAYBACK RATE: \(rateEvent.playbackRate)x")
            return self?.handleChangePlaybackRate(rate: Float(rateEvent.playbackRate)) ?? .noActionableNowPlayingItem
        }
        commandTargets.append(rateTarget)

        Log.debug(#file, "🎮 \(commandTargets.count) remote command targets registered")
    }

    private func removeAllTargets() {
        // Remove specific targets we added (not all targets, which could affect other components)
        for target in commandTargets {
            commandCenter.playCommand.removeTarget(target)
            commandCenter.pauseCommand.removeTarget(target)
            commandCenter.togglePlayPauseCommand.removeTarget(target)
            commandCenter.skipForwardCommand.removeTarget(target)
            commandCenter.skipBackwardCommand.removeTarget(target)
            commandCenter.changePlaybackRateCommand.removeTarget(target)
        }
        commandTargets.removeAll()
    }

    // MARK: - Command Handlers

    /// Routes commands to the active AudiobookManager via AudiobookSessionManager.
    /// Returns .noActionableNowPlayingItem if no playback is active.
    ///
    /// Note: These handlers must work even when the phone UI has never been opened.
    /// The session manager's `hasActiveManager` flag is false until a book is
    /// opened; opening the book binds the manager directly on the session.

    /// The gate shared by all six remote-command handlers. When a manager is
    /// bound the toolkit's `MediaControlPublisher` performs the actual transport
    /// action, so we return `.success` to acknowledge the command; with no
    /// manager there is nothing to act on, so `.noActionableNowPlayingItem`
    /// (which keeps the lock screen from presenting a dead control before a book
    /// is opened). Extracted as a `nonisolated static` PURE function so the gate
    /// is unit-testable directly — MPRemoteCommand exposes no public
    /// invoke-handler-and-read-status API, so this is the seam that lets a test
    /// kill the gate-inversion mutant without an MPRemoteCommand invocation or a
    /// bound-manager fixture. `internal` for `@testable` access.
    nonisolated static func remoteCommandStatus(hasActiveManager: Bool) -> MPRemoteCommandHandlerStatus {
        hasActiveManager ? .success : .noActionableNowPlayingItem
    }

    nonisolated private func handlePlay() -> MPRemoteCommandHandlerStatus {
        // Off-main-safe: reads the nonisolated snapshot, NOT the @MainActor
        // `audiobookSessionProvider().hasActiveManager` (which would trip
        // dispatch_assert_queue when this handler runs on MediaRemote's queue).
        let hasManager = hasActiveManagerSnapshot()
        Log.debug(#file, "🎮 handlePlay - manager: \(hasManager)")
        return Self.remoteCommandStatus(hasActiveManager: hasManager)
    }

    nonisolated private func handlePause() -> MPRemoteCommandHandlerStatus {
        // Off-main-safe: reads the nonisolated snapshot, NOT the @MainActor
        // `audiobookSessionProvider().hasActiveManager` (which would trip
        // dispatch_assert_queue when this handler runs on MediaRemote's queue).
        let hasManager = hasActiveManagerSnapshot()
        Log.debug(#file, "🎮 handlePause - manager: \(hasManager)")
        return Self.remoteCommandStatus(hasActiveManager: hasManager)
    }

    nonisolated private func handleTogglePlayPause() -> MPRemoteCommandHandlerStatus {
        // Off-main-safe: reads the nonisolated snapshot, NOT the @MainActor
        // `audiobookSessionProvider().hasActiveManager` (which would trip
        // dispatch_assert_queue when this handler runs on MediaRemote's queue).
        let hasManager = hasActiveManagerSnapshot()
        Log.debug(#file, "🎮 handleTogglePlayPause - manager: \(hasManager)")
        return Self.remoteCommandStatus(hasActiveManager: hasManager)
    }

    nonisolated private func handleSkipForward(interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
        // Off-main-safe: reads the nonisolated snapshot, NOT the @MainActor
        // `audiobookSessionProvider().hasActiveManager` (which would trip
        // dispatch_assert_queue when this handler runs on MediaRemote's queue).
        let hasManager = hasActiveManagerSnapshot()
        Log.debug(#file, "🎮 handleSkipForward(\(interval)s) - manager: \(hasManager)")
        return Self.remoteCommandStatus(hasActiveManager: hasManager)
    }

    nonisolated private func handleSkipBackward(interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
        // Off-main-safe: reads the nonisolated snapshot, NOT the @MainActor
        // `audiobookSessionProvider().hasActiveManager` (which would trip
        // dispatch_assert_queue when this handler runs on MediaRemote's queue).
        let hasManager = hasActiveManagerSnapshot()
        Log.debug(#file, "🎮 handleSkipBackward(\(interval)s) - manager: \(hasManager)")
        return Self.remoteCommandStatus(hasActiveManager: hasManager)
    }

    nonisolated private func handleChangePlaybackRate(rate: Float) -> MPRemoteCommandHandlerStatus {
        // Off-main-safe: reads the nonisolated snapshot, NOT the @MainActor
        // `audiobookSessionProvider().hasActiveManager` (which would trip
        // dispatch_assert_queue when this handler runs on MediaRemote's queue).
        let hasManager = hasActiveManagerSnapshot()
        Log.debug(#file, "🎮 handleChangePlaybackRate(\(rate)x) - manager: \(hasManager)")
        return Self.remoteCommandStatus(hasActiveManager: hasManager)
    }
}
