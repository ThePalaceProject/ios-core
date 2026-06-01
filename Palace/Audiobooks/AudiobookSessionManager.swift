//
//  AudiobookSessionManager.swift
//  Palace
//
//  Central manager for audiobook playback across phone and CarPlay.
//  Provides a single source of truth for playback state to avoid
//  race conditions and duplicate state management.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import MediaPlayer
import PalaceAudiobookToolkit
import PalaceLogging
import PalaceNetwork

// MARK: - AudiobookSessionState

/// Represents the current state of audiobook playback
public enum AudiobookSessionState: Equatable {
    case idle
    case loading(bookId: String)
    case playing(bookId: String)
    case paused(bookId: String)
    case error(bookId: String, message: String)

    public var bookId: String? {
        switch self {
        case .idle: return nil
        case .loading(let id), .playing(let id), .paused(let id), .error(let id, _): return id
        }
    }

    public var isActive: Bool {
        switch self {
        case .playing, .paused, .loading: return true
        case .idle, .error: return false
        }
    }
}

// MARK: - AudiobookSessionError

public enum AudiobookSessionError: Error, Equatable {
    case notAuthenticated
    case notDownloaded
    case networkUnavailable
    case wifiRequired
    case manifestLoadFailed
    case playerCreationFailed
    case alreadyLoading
    case unknown(String)

    var localizedDescription: String {
        switch self {
        case .notAuthenticated:
            return "Please sign in to your library account to play this audiobook."
        case .notDownloaded:
            return "This audiobook needs to be downloaded first."
        case .networkUnavailable:
            return "No network connection. Please try again when online."
        case .wifiRequired:
            return Strings.Settings.downloadRestrictedToWiFi
        case .manifestLoadFailed:
            return "Failed to load audiobook data. Please try again."
        case .playerCreationFailed:
            return "Failed to create audio player. Please try again."
        case .alreadyLoading:
            return "Audiobook is already loading."
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - AudiobookSessionManager

/// Singleton manager that owns audiobook playback state.
/// Thread-safe via MainActor isolation.
@MainActor
public final class AudiobookSessionManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: AudiobookSessionState = .idle
    @Published public private(set) var currentBook: TPPBook?
    @Published public private(set) var currentChapters: [Chapter] = []
    @Published public private(set) var currentChapter: Chapter?
    @Published public private(set) var currentPosition: TrackPosition?
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var coverImage: UIImage?

    // MARK: - Internal State

    private(set) var audiobook: Audiobook?
    private(set) var manager: AudiobookManager?
    private(set) var playbackModel: AudiobookPlaybackModel?
    private(set) var nowPlayingCoordinator: NowPlayingCoordinator?

    /// Surface for the `AudiobookSessionManaging` protocol — exposes whether
    /// an `AudiobookManager` is bound without leaking the toolkit type
    /// through the protocol.
    public var hasActiveManager: Bool { manager != nil }

    /// DRM decryptor tied to the currently loaded audiobook. Owned atomically
    /// alongside manager/audiobook/playbackModel so stopPlayback can release
    /// all four together — preventing the previous LCP Publication from
    /// keeping Readium file handles open while a new audiobook opens.
    private var decryptor: DRMDecryptor?

    /// The loader for the in-flight open, if any. Cancelled when a new open
    /// supersedes it or when stopPlayback is called mid-load.
    private var currentLoader: AudiobookLoader?

    /// Monotonically-increasing token that makes sure late completions from
    /// a superseded loader can't bind their manager onto the session.
    private var loadGeneration: UInt64 = 0

    /// True once `.playbackBegan` has fired at least once during the current
    /// session. Used to distinguish a cold-load failure (first chapter never
    /// became ready — book is broken) from a mid-playback failure (chapter
    /// boundary error — user is already listening, can scrub back). Cold-
    /// load failures dismiss the dead player UI and show an OK-only
    /// "unavailable" alert; mid-playback failures keep the player open with
    /// the toolkit's toast.
    private var hasEverStartedPlayback: Bool = false

    private var managerCancellables = Set<AnyCancellable>()

    /// Cancellables tied to the manager's lifetime (singleton) — NOT cleared
    /// on stopPlayback. Used for the phone-side error subscriber that presents
    /// alerts for user-actionable session errors.
    private var lifecycleCancellables = Set<AnyCancellable>()

    // MARK: - Publishers for External Observers

    /// Emits when playback state changes (for CarPlay UI updates)
    public let playbackStatePublisher = PassthroughSubject<AudiobookSessionState, Never>()

    /// Emits when chapter list or current chapter changes
    public let chapterUpdatePublisher = PassthroughSubject<(chapters: [Chapter], current: Chapter?), Never>()

    /// Emits errors for UI display
    public let errorPublisher = PassthroughSubject<AudiobookSessionError, Never>()

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let settings: TPPSettings
    /// Reachability is resolved on demand because it's a process-wide
    /// network monitor singleton; the closure makes it overridable in tests
    /// without forcing every consumer to wire one up.
    private let reachabilityProvider: () -> Reachability
    /// Cover registry resolved lazily so a future migration that injects an
    /// alternate cache (or a no-op for tests) doesn't force a touch here.
    private let bookCoverRegistryProvider: () -> TPPBookCoverRegistry
    /// Navigation hub resolved lazily — the hub itself is process-wide and
    /// references a UIKit coordinator that isn't valid at construction time
    /// during cold launch / CarPlay background launch.
    private let navigationCoordinatorHubProvider: () -> NavigationCoordinatorHub

    // MARK: - F-011 readiness-gate injection points
    //
    // PR #990 introduced a race where Palace's first `play(at:)` could fire
    // before the toolkit's player coordinator finished initializing. These
    // closures let production wire a real `PlayerReadinessProbe` (polls
    // `Player.isLoaded`) and the real player-command forwarder, while tests
    // inject deterministic stubs. See `PlaybackReadinessGate.swift`.

    /// Builds a readiness probe for a given toolkit Player. The probe drives
    /// a `PlaybackReadinessGate` until the player reports loaded.
    private let readinessProbeFactory: @MainActor (Player) -> PlaybackReadinessProbing

    /// Builds the play-command forwarder for a given toolkit Player. This
    /// is the seam that lets unit tests assert on `play(at:)` invocation
    /// counts without owning a real Player.
    private let playbackCommandFactory: @MainActor (Player) -> PlaybackEngineCommanding

    /// Total budget the readiness gate will wait for the toolkit's player
    /// coordinator to finish initializing on the first open. 2.0s matches
    /// the contract from `A-Audiobook-FirstOpen.md` — long enough for
    /// realistic Findaway / OpenAccess init (~80ms typical), short enough
    /// that a stuck coordinator surfaces a load failure rather than a
    /// permanent UI hang. The gate is bypassed entirely for LCP audiobooks
    /// (see FINDING-B note in `startPlaybackAndSyncPosition`) where this
    /// timeout would otherwise mis-fire.
    private let readinessTimeout: TimeInterval

    // MARK: - Initialization

    /// Designated init — every dependency is explicit. `private` so the
    /// singleton accessor remains the only entry point in production.
    private init(
        bookRegistry: TPPBookRegistryProvider,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        reachabilityProvider: @escaping () -> Reachability,
        bookCoverRegistryProvider: @escaping () -> TPPBookCoverRegistry,
        navigationCoordinatorHubProvider: @escaping () -> NavigationCoordinatorHub,
        readinessProbeFactory: @escaping @MainActor (Player) -> PlaybackReadinessProbing,
        playbackCommandFactory: @escaping @MainActor (Player) -> PlaybackEngineCommanding,
        readinessTimeout: TimeInterval
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.settings = settings
        self.reachabilityProvider = reachabilityProvider
        self.bookCoverRegistryProvider = bookCoverRegistryProvider
        self.navigationCoordinatorHubProvider = navigationCoordinatorHubProvider
        self.readinessProbeFactory = readinessProbeFactory
        self.playbackCommandFactory = playbackCommandFactory
        self.readinessTimeout = readinessTimeout
        Log.info(#file, "AudiobookSessionManager initialized")
        nowPlayingCoordinator = NowPlayingCoordinator()
        // Note: Remote commands are handled by the toolkit's MediaControlPublisher.
        // This manager now owns the full audiobook lifecycle (load → bind → play)
        // directly via AudiobookLoader; no pub/sub handoff is needed.
        subscribeToPhoneSideErrorAlerts()
    }

    /// AppContainer-friendly initializer. Used by future call sites that
    /// thread the container down to here. Provider closures default to
    /// `.shared` accessors since AppContainer doesn't currently hold
    /// Reachability / TPPBookCoverRegistry / NavigationCoordinatorHub.
    ///
    /// `readinessProbeFactory` / `playbackCommandFactory` / `readinessTimeout`
    /// default to production wiring (poll `Player.isLoaded`, forward to
    /// `Player.play(at:)`, 2.0s budget). LCP audiobooks bypass the gate
    /// entirely — see the FINDING-B note in `startPlaybackAndSyncPosition`.
    /// Tests pass shorter values to keep suite time down.
    convenience init(
        appContainer: AppContainer,
        reachabilityProvider: @escaping () -> Reachability = { AppContainer.production().reachability },
        bookCoverRegistryProvider: @escaping () -> TPPBookCoverRegistry = { TPPBookCoverRegistry.shared },
        navigationCoordinatorHubProvider: @escaping () -> NavigationCoordinatorHub = { AppContainer.production().navigationCoordinatorHub },
        readinessProbeFactory: @escaping @MainActor (Player) -> PlaybackReadinessProbing = { player in
            PlayerReadinessProbe(isLoadedSnapshot: { [weak player] in player?.isLoaded ?? false })
        },
        playbackCommandFactory: @escaping @MainActor (Player) -> PlaybackEngineCommanding = { player in
            ToolkitPlayerCommand(player: player)
        },
        readinessTimeout: TimeInterval = 2.0
    ) {
        self.init(
            bookRegistry: appContainer.bookRegistry,
            accountsManager: appContainer.accountsManager,
            settings: appContainer.settings,
            reachabilityProvider: reachabilityProvider,
            bookCoverRegistryProvider: bookCoverRegistryProvider,
            navigationCoordinatorHubProvider: navigationCoordinatorHubProvider,
            readinessProbeFactory: readinessProbeFactory,
            playbackCommandFactory: playbackCommandFactory,
            readinessTimeout: readinessTimeout
        )
    }

    /// Presents user-facing alerts for validation errors published to
    /// `errorPublisher`. Before this subscriber existed, only CarPlay listened
    /// to `errorPublisher` — so phone users got no feedback when an open
    /// failed at the validation stage (WiFi-only+cellular, not-authenticated,
    /// not-downloaded, offline+streaming). Loader failures and cold-load
    /// playback failures have their own alert paths (BookService.
    /// showAudiobookTryAgainError and the .playbackFailed cold-load branch);
    /// those are explicitly skipped here to avoid double-alerting.
    private func subscribeToPhoneSideErrorAlerts() {
        errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { error in
                Self.presentPhoneSideAlert(for: error)
            }
            .store(in: &lifecycleCancellables)
    }

    static func presentPhoneSideAlert(for error: AudiobookSessionError) {
        guard let alertContent = phoneAlertContent(for: error) else { return }
        let alert = TPPAlertUtils.alert(title: alertContent.title, message: alertContent.message)
        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: alert,
            viewController: nil,
            animated: true,
            completion: nil
        )
    }

    /// Maps session errors to phone-alert (title, message) pairs. Returns nil
    /// for errors that have other dedicated presentation paths — keep this
    /// switch aligned with those paths so no case is alerted twice.
    static func phoneAlertContent(for error: AudiobookSessionError) -> (title: String, message: String)? {
        switch error {
        case .wifiRequired:
            return (Strings.Settings.wifiRequired, Strings.Settings.downloadRestrictedToWiFi)
        case .notAuthenticated:
            return (Strings.Error.signInErrorTitle, error.localizedDescription)
        case .notDownloaded:
            return (Strings.Generic.error, error.localizedDescription)
        case .networkUnavailable:
            return (Strings.Error.networkUnavailableErrorTitle, error.localizedDescription)
        case .manifestLoadFailed, .playerCreationFailed, .alreadyLoading, .unknown:
            // Loader failures → BookService.showAudiobookTryAgainError.
            // Cold-load .unknown("Playback failed") → cold-load alert branch.
            // .alreadyLoading is a programmer-facing signal, not user-facing.
            return nil
        }
    }

    // MARK: - Public API

    /// Opens and starts playing an audiobook.
    /// This is the single entry point for playback from both phone and CarPlay.
    ///
    /// Ordering invariant: the previous session (if any) is stopped — which
    /// releases its DRM decryptor and tears down its manager — BEFORE the
    /// new load begins. This is what prevents the "opening third audiobook
    /// hangs" bug: a stale LCP Publication can no longer race the new
    /// publicationOpener.open().
    ///
    /// - Parameters:
    ///   - book: The book to play
    ///   - startPlaying: Whether to auto-start playback (default: true)
    /// - Returns: Result indicating success or failure
    @discardableResult
    public func openAudiobook(_ book: TPPBook, startPlaying: Bool = true) async -> Result<Void, AudiobookSessionError> {
        Log.info(#file, "Opening audiobook: '\(book.title)' (id: \(book.identifier))")

        if case .loading(let loadingId) = state, loadingId == book.identifier {
            Log.warn(#file, "Audiobook already loading: \(book.identifier)")
            return .failure(.alreadyLoading)
        }

        let isSameBook = currentBook?.identifier == book.identifier

        if state.isActive {
            // FINDING-D: skip the teardown's final-position save when re-opening
            // the SAME book; the prior loan's live position would otherwise
            // leak into the freshly-borrowed registry record. Decision is
            // delegated to `PlaybackOpenPolicy.decide` so mutation tests pin
            // the predicate semantics; see `AudiobookPositionPolicy.swift`.
            let decision = PlaybackOpenPolicy.decide(
                isReBorrowOfSameBook: isSameBook,
                hasDecryptor: false  // not yet known; teardown decision only depends on isSameBook
            )
            await stopPlayback(
                dismissPhoneUI: !isSameBook,
                persistFinalPosition: decision.persistFinalPositionOnTeardown
            )
        }

        if let error = await validateRequirements(for: book) {
            Log.error(#file, "Validation failed: \(error)")
            state = .error(bookId: book.identifier, message: error.localizedDescription)
            errorPublisher.send(error)
            return .failure(error)
        }

        state = .loading(bookId: book.identifier)
        currentBook = book
        hasEverStartedPlayback = false
        playbackStatePublisher.send(state)

        loadGeneration &+= 1
        let generation = loadGeneration
        let loader = AudiobookLoader()
        currentLoader = loader

        return await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<Result<Void, AudiobookSessionError>, Never>) in
            loader.load(book) { [weak self] result in
                Task { @MainActor in
                    guard let self = self else {
                        continuation.resume(returning: .failure(.unknown("Session manager deallocated")))
                        return
                    }
                    // If a newer openAudiobook has started, drop this completion.
                    guard self.loadGeneration == generation else {
                        Log.info(#file, "Superseded audiobook load completion — ignoring")
                        continuation.resume(returning: .failure(.alreadyLoading))
                        return
                    }
                    self.currentLoader = nil

                    switch result {
                    case .success(let loaded):
                        Log.info(#file, "Audiobook loaded successfully: '\(book.title)'")
                        self.bind(loaded: loaded, for: book, startPlaying: startPlaying)
                        continuation.resume(returning: .success(()))

                    case .failure(let loadError):
                        Log.error(#file, "Failed to load audiobook: \(loadError)")
                        let sessionError = Self.mapLoadError(loadError)
                        self.state = .error(bookId: book.identifier, message: sessionError.localizedDescription)
                        self.errorPublisher.send(sessionError)
                        // Surface the retry-with-dialog UX (PP-3707) for user-visible
                        // load failures. Skip for cancellation so a superseded open
                        // doesn't flash an error on screen.
                        if case .cancelled = loadError {
                            // no-op
                        } else if Self.shouldTriggerSAMLReauthForLoadFailure(
                            loadError: loadError,
                            userAccount: self.accountsManager.currentUserAccount,
                            currentBook: self.currentBook
                        ) {
                            // HelpSpot 17727: SAML credentials went stale upstream
                            // (network layer marked them so on a 401). Showing the
                            // generic "Try Again" alert is useless — Try Again will
                            // hit the same 401. Trigger SAML re-auth and re-attempt
                            // the open after credentials refresh.
                            Log.info(#file, "SAML credentials stale on audiobook open failure — triggering re-auth before showing error (HelpSpot 17727)")
                            let userAccount = self.accountsManager.currentUserAccount
                            let reauthenticator = TPPReauthenticator()
                            reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true) { [weak self] in
                                Task { @MainActor in
                                    guard let self else { return }
                                    // Same-book guard — a newer open may have superseded this one.
                                    guard self.currentBook?.identifier == book.identifier else { return }
                                    guard self.accountsManager.currentUserAccount.hasCredentials() else {
                                        Log.info(#file, "SAML re-auth cancelled or failed — falling back to standard try-again error")
                                        BookService.showAudiobookTryAgainError(book: book, onFinish: nil)
                                        return
                                    }
                                    Log.info(#file, "SAML re-auth succeeded — re-attempting audiobook open")
                                    _ = await self.openAudiobook(book, startPlaying: startPlaying)
                                }
                            }
                        } else {
                            BookService.showAudiobookTryAgainError(book: book, onFinish: nil)
                        }
                        continuation.resume(returning: .failure(sessionError))
                    }
                }
            }
        }
    }

    static func mapLoadError(_ error: AudiobookLoadError) -> AudiobookSessionError {
        switch error {
        case .cancelled:
            return .unknown("Load cancelled")
        case .tokenRefreshFailed, .missingCredentialsForTokenRefresh:
            return .notAuthenticated
        case .manifestFetchFailed, .manifestParseFailed, .manifestSerializationFailed, .manifestDecodingFailed:
            return .manifestLoadFailed
        case .lcpNotAvailable, .lcpInstantiationFailed, .lcpDecryptionFailed,
             .licenseDownloadFailed, .licenseSaveFailed, .missingFulfillURL, .missingContentDirectory:
            return .manifestLoadFailed
        case .vendorKeyUpdateFailed(let nsError):
            return .unknown(nsError.localizedDescription)
        case .factoryFailed:
            return .playerCreationFailed
        }
    }

    /// Plays the current audiobook
    public func play() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot play - no active manager")
            return
        }

        manager.play()
        nowPlayingCoordinator?.setPlaybackState(playing: true)
    }

    /// Pauses the current audiobook
    public func pause() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot pause - no active manager")
            return
        }

        manager.pause()
        nowPlayingCoordinator?.setPlaybackState(playing: false)
    }

    /// Toggles play/pause
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Skips to a specific chapter
    public func skipToChapter(at index: Int) {
        guard let manager = manager,
              index >= 0 && index < currentChapters.count else {
            Log.warn(#file, "Invalid chapter index: \(index)")
            return
        }

        let chapter = currentChapters[index]
        // Toolkit T1 migration: player.play(at:) is now `async throws`.
        // Fire-and-forget at the sync boundary; errors are logged downstream.
        Task { @MainActor in
            try? await manager.audiobook.player.play(at: chapter.position)
        }

        Log.debug(#file, "Skipping to chapter: '\(chapter.title)'")
    }

    /// Cycles through playback rates. Driven by CarPlay / remote-control
    /// "change playback rate" commands — the now-playing screen UI uses the
    /// speed bottom sheet instead of cycling.
    public func cyclePlaybackRate() -> PlaybackRate {
        guard let player = manager?.audiobook.player else {
            return .normalTime
        }

        let rates = PlaybackRate.presets
        let currentIndex = rates.firstIndex(of: player.playbackRate)
            ?? (rates.firstIndex(of: .normalTime) ?? 0)
        let nextIndex = (currentIndex + 1) % rates.count
        let newRate = rates[nextIndex]

        player.playbackRate = newRate
        nowPlayingCoordinator?.updatePlaybackRate(newRate)

        Log.debug(#file, "Playback rate changed to: \(PlaybackRate.convert(rate: newRate))x")
        return newRate
    }

    /// Stops playback and clears current session, atomically releasing the
    /// DRM decryptor alongside the manager/audiobook/playbackModel. This is
    /// the only place the previous LCP Publication's file handles are dropped.
    /// - Parameters:
    ///   - dismissPhoneUI: Whether to dismiss the player UI on the phone (default: true)
    ///   - persistFinalPosition: Whether to save the current live position to the
    ///     registry as part of teardown (default: true). Set to `false` when
    ///     tearing down to re-open the SAME book — between the prior session's
    ///     last save and now the user may have returned and re-borrowed the
    ///     book; saving a stale "live" position would inject it into the
    ///     freshly-borrowed registry record, making the next open seek to a
    ///     pre-return offset. (FINDING-D: position-leak-across-reborrow.)
    public func stopPlayback(dismissPhoneUI: Bool = true, persistFinalPosition: Bool = true) async {
        Log.info(#file, "Stopping playback (dismissPhoneUI: \(dismissPhoneUI), persistFinalPosition: \(persistFinalPosition))")

        // Cancel any in-flight loader so its completion is ignored.
        currentLoader?.cancel()
        currentLoader = nil

        let bookId = currentBook?.identifier

        if persistFinalPosition {
            // Prefer the live position from the player over the cached value, which
            // may lag behind if the user scrubbed or the position update hadn't fired yet.
            let livePosition = manager?.audiobook.player.currentTrackPosition ?? currentPosition
            if let position = livePosition {
                manager?.saveLocation(position)
            }
        }

        managerCancellables.removeAll()

        manager?.pause()
        manager?.unload()

        // Release DRM decryptor BEFORE nil-ing the manager so there is no window
        // where the decryptor could be asked to open a new Publication.
        #if LCP
        (decryptor as? LCPAudiobooks)?.releaseResources()
        #endif
        decryptor = nil

        if dismissPhoneUI, let bookId = bookId {
            dismissPlayerOnPhone(bookId: bookId)
        }

        manager = nil
        audiobook = nil
        playbackModel = nil
        currentBook = nil
        currentChapters = []
        currentChapter = nil
        currentPosition = nil
        isPlaying = false
        coverImage = nil

        nowPlayingCoordinator?.clearNowPlaying()

        state = .idle
        playbackStatePublisher.send(state)

        Log.info(#file, "Playback stopped and session cleared")
    }

    /// Dismisses the audiobook player view on the phone
    private func dismissPlayerOnPhone(bookId: String) {
        if let coordinator = navigationCoordinatorHubProvider().coordinator {
            Log.info(#file, "Dismissing player UI on phone for book: \(bookId)")
            coordinator.removeAudioModel(forBookId: bookId)
            coordinator.popToRoot()
        }
    }

    /// Updates cover image (called when image loads asynchronously)
    public func updateCoverImage(_ image: UIImage?) {
        coverImage = image
        nowPlayingCoordinator?.updateArtwork(image)
    }

    // MARK: - Manager Binding (Direct, post-load)

    /// Binds a freshly-loaded audiobook: takes ownership of the manager,
    /// decryptor, audiobook, and playback model; pushes navigation; loads
    /// cover art; restores position; starts playback; and kicks off remote
    /// position sync. The previous session must already have been stopped
    /// via `stopPlayback` — the openAudiobook flow guarantees this.
    private func bind(loaded: LoadedAudiobook, for book: TPPBook, startPlaying: Bool) {
        Log.info(#file, "Binding loaded audiobook manager")

        managerCancellables.removeAll()
        let newManager = loaded.manager

        self.manager = newManager
        self.audiobook = loaded.audiobook
        self.decryptor = loaded.decryptor
        self.playbackModel = loaded.playbackModel
        self.currentChapters = Self.normalizedChapters(
            for: loaded.audiobook.tableOfContents
        )

        newManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] managerState in
                self?.handleManagerState(managerState)
            }
            .store(in: &managerCancellables)

        newManager.audiobook.player.positionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                self?.handlePositionUpdate(position)
            }
            .store(in: &managerCancellables)

        currentChapter = newManager.currentChapter
        chapterUpdatePublisher.send((chapters: currentChapters, current: currentChapter))

        presentCoverArtAndNavigation(for: book, loaded: loaded)

        if startPlaying {
            startPlaybackAndSyncPosition(for: book, loaded: loaded)
        }

        if newManager.audiobook.player.isPlaying {
            isPlaying = true
            state = .playing(bookId: book.identifier)
        } else {
            state = .paused(bookId: book.identifier)
        }
        playbackStatePublisher.send(state)

        if let position = newManager.audiobook.player.currentTrackPosition {
            updateNowPlayingInfo(position: position)
        }

        Log.info(#file, "Bound audiobook - chapters: \(currentChapters.count), isPlaying: \(isPlaying)")
    }

    private func presentCoverArtAndNavigation(for book: TPPBook, loaded: LoadedAudiobook) {
        if let lowRes = book.coverImage ?? book.thumbnailImage {
            loaded.playbackModel.updateCoverImage(lowRes)
            updateCoverImage(lowRes)
        }
        let coverRegistry = bookCoverRegistryProvider()
        Task { [weak self, weak playbackModel = loaded.playbackModel] in
            guard let img = await coverRegistry.coverImage(for: book) else { return }
            await MainActor.run {
                playbackModel?.updateCoverImageAnimated(img)
                self?.updateCoverImage(img)
            }
        }

        let route = BookRoute(id: book.identifier)
        if let coordinator = navigationCoordinatorHubProvider().coordinator {
            Log.debug(#file, "Presenting audiobook player route for \(book.identifier)")
            coordinator.storeAudioModel(loaded.playbackModel, forBookId: route.id)
            coordinator.pushAudioRoute(route)
        } else {
            Log.info(#file, "No navigation coordinator (CarPlay background launch?) — playback will start without phone UI")
        }
    }

    private func startPlaybackAndSyncPosition(for book: TPPBook, loaded: LoadedAudiobook) {
        let shouldRestore = shouldRestoreBookmarkPosition(for: book)
        let localPosition = shouldRestore ? getValidLocalPosition(book: book, audiobook: loaded.audiobook) : nil

        let initialPosition: TrackPosition
        if let local = localPosition {
            Log.debug(#file, "Starting playback with local position: track=\(local.track.key), timestamp=\(local.timestamp)")
            initialPosition = local
        } else if let firstTrack = loaded.audiobook.tableOfContents.allTracks.first {
            Log.debug(#file, "Starting '\(book.title)' from beginning - no saved position")
            initialPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: loaded.audiobook.tableOfContents.tracks)
        } else {
            Log.error(#file, "No tracks available in audiobook")
            return
        }

        // F-011 fix (PR #990 toolkit overhaul regression): await the
        // toolkit's player-coordinator-ready signal BEFORE issuing the
        // first `play(at:)`. Pre-fix Palace fired play immediately and the
        // player silently dropped it on first-open (engine still
        // initializing), leaving NowPlaying UI mounted with no audio.
        // See `audiobook_first_open_hang_3_2_0.md`.
        //
        // The probe + command are built from the injected factories so
        // tests can substitute spies; the readiness-gate sub-flow itself
        // is extracted into `awaitReadinessAndIssueFirstPlay` so a wiring
        // test can drive it directly without owning a real Player.
        let probe = readinessProbeFactory(loaded.manager.audiobook.player)
        let command = playbackCommandFactory(loaded.manager.audiobook.player)
        let budget = readinessTimeout
        let bookId = book.identifier
        // FINDING-B: LCP-streaming players (Palace Marketplace) expose
        // `isLoaded` as a function of AVPlayer.timeControlStatus == .playing —
        // which requires `play()` to have already been called. The pre-play
        // readiness gate (introduced by PR #1020 for the Findaway/OpenAccess
        // first-open hang in F-011) would therefore deadlock on LCP: we'd
        // wait forever for an isLoaded signal that only fires AFTER the very
        // play call we're trying to gate. LCPStreamingPlayer has its own
        // internal 30s load timeout that surfaces a .failed playback state
        // if the engine genuinely doesn't start, so the gate's hang-
        // detection role is already covered by the toolkit on this path.
        // Skip the gate for LCP audiobooks; keep it for the non-decryptor
        // (Findaway / OpenAccess / Overdrive) paths where it does its job.
        // Decision is delegated to `PlaybackOpenPolicy.decideForLoad` so both
        // the `decryptor != nil` predicate AND the `hasDecryptor →
        // bypassReadinessGate` mapping are mutation-testable from
        // `PlaybackOpenPolicyTests`. See `AudiobookPositionPolicy.swift`.
        let isLCPAudiobook = PlaybackOpenPolicy.decideForLoad(
            decryptor: loaded.decryptor
        ).bypassReadinessGate

        Task { @MainActor in
            loaded.playbackModel.currentLocation = initialPosition
            loaded.playbackModel.beginSaveSuppression(for: 3.0)
            if isLCPAudiobook {
                do {
                    try await command.play(at: initialPosition)
                    Log.info(#file, "🎵 Playback started at initial position (LCP path — gate bypassed)")
                } catch {
                    Log.error(#file, "Playback start error (LCP path): \(error)")
                }
            } else {
                await self.awaitReadinessAndIssueFirstPlay(
                    bookId: bookId,
                    initialPosition: initialPosition,
                    probe: probe,
                    command: command,
                    budget: budget
                )
            }
        }

        let audiobookRef = loaded.audiobook
        let playbackModelRef = loaded.playbackModel
        // `syncLocation(for:)` lives on the concrete TPPBookRegistry as an
        // extension; the provider protocol doesn't expose it. Cast at the
        // call site so the rest of this file talks to the protocol.
        // syncLocation(for:) lives on the concrete TPPBookRegistry as an
        // extension; the provider protocol doesn't expose it. If the injected
        // bookRegistry isn't the concrete app-scoped instance, skip the
        // remote-bookmark lookup rather than fall through to a singleton —
        // tests pass mocks here on purpose.
        guard let concreteRegistry = bookRegistry as? TPPBookRegistry else {
            // No-op: progress-syncing requires the production registry. In a
            // mock-injected test, the local position alone is the best signal.
            return
        }
        concreteRegistry.syncLocation(for: book) { [weak self, weak playbackModel = playbackModelRef, localPosition] (remoteBookmark: AudioBookmark?) in
            guard let remoteBookmark = remoteBookmark,
                  let remote = TrackPosition(
                    audioBookmark: remoteBookmark,
                    toc: audiobookRef.tableOfContents.toc,
                    tracks: audiobookRef.tableOfContents.tracks
                  ) else {
                Log.debug(#file, "No remote position found - continuing with local position")
                return
            }
            let formatter = ISO8601DateFormatter()
            let localSaveDate = localPosition.flatMap { formatter.date(from: $0.lastSavedTimeStamp) }
            let remoteSaveDate = formatter.date(from: remote.lastSavedTimeStamp)
            guard let remoteDate = remoteSaveDate else { return }
            let shouldUseRemote: Bool
            if let localDate = localSaveDate {
                shouldUseRemote = remoteDate.timeIntervalSince(localDate) > 5.0
            } else {
                shouldUseRemote = true
            }
            guard shouldUseRemote else {
                Log.debug(#file, "Local position is current - keeping local position")
                return
            }
            Log.info(#file, "📡 Remote position is newer - seeking to remote: track=\(remote.track.key), timestamp=\(remote.timestamp)")
            Task { @MainActor in
                // Route through session manager so we seek the CURRENT manager,
                // not a stale one if the user switched books mid-sync.
                guard let self = self,
                      let currentMgr = self.manager,
                      self.currentBook?.identifier == bookId else {
                    return
                }
                playbackModel?.currentLocation = remote
                // Toolkit T1 migration: player.play(at:) is now `async throws`.
                Task { @MainActor in
                    do {
                        try await currentMgr.audiobook.player.play(at: remote)
                    } catch {
                        Log.error(#file, "Failed to seek to remote position: \(error)")
                    }
                }
            }
        }

        Task { @MainActor [weak playbackModel = loaded.playbackModel] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            playbackModel?.persistLocation()
        }
    }

    // MARK: - Readiness gate wiring (F-011)

    /// Awaits readiness via the supplied probe + gate, then issues exactly
    /// one `play(at:)` through the supplied command. On timeout, surfaces
    /// the load failure on the session manager (`state = .error`,
    /// `errorPublisher.send(.playerCreationFailed)`); on any other error
    /// after readiness, the failure is logged but state is left to the
    /// toolkit's regular failure path (which will fire `playbackFailed`).
    ///
    /// Extracted from `startPlaybackAndSyncPosition` for testability — the
    /// production code path that runs at first-open lives entirely in this
    /// method, so a wiring test that calls it with spy probe + command
    /// proves the readiness-await-then-play sequencing fires.
    ///
    /// `internal` (not `private`) so `@testable import Palace` tests can
    /// drive it directly with stubs; this is the only seam by which the
    /// F-011 fix's wiring can be exercised without owning a full toolkit
    /// `Player`.
    @MainActor
    internal func awaitReadinessAndIssueFirstPlay(
        bookId: String,
        initialPosition: TrackPositionShape,
        probe: PlaybackReadinessProbing,
        command: PlaybackEngineCommanding,
        budget: TimeInterval
    ) async {
        let gate = PlaybackReadinessGate()
        probe.start(driving: gate)
        defer { probe.stop() }
        do {
            try await PlaybackReadinessGate.awaitReadinessAndPlay(
                at: initialPosition,
                gate: gate,
                timeout: budget,
                command: command
            )
            Log.info(#file, "🎵 Playback started at initial position (post-readiness)")
        } catch PlaybackReadinessError.timeout {
            Log.error(#file, "First-open readiness gate timed out after \(budget)s — surfacing as load failure (PP-4436 / F-011)")
            self.state = .error(bookId: bookId, message: "Playback engine did not initialize in time")
            self.errorPublisher.send(.playerCreationFailed)
            self.playbackStatePublisher.send(self.state)
        } catch {
            Log.error(#file, "Playback start error after readiness: \(error)")
        }
    }

    // MARK: - Chapter TOC normalization

    /// Returns the chapter list that should drive `currentChapters`. When the
    /// raw TOC is oversubdivided relative to the actual track count (>1.5x),
    /// collapses adjacent same-track entries to keep the UI showing chapters
    /// (one per track) instead of sections/paragraphs. See
    /// `ChapterTOCNormalizer` for the threshold rationale.
    ///
    /// Static + pure so the decision is unit-testable without a real
    /// `AudiobookTableOfContents` — wrapper `normalizedChaptersCount(
    /// tocCount:trackCount:)` provides a primitive entry point that tests
    /// can hit without constructing toolkit types.
    static func normalizedChapters(for toc: AudiobookTableOfContents) -> [Chapter] {
        let chapters = toc.toc
        let trackCount = toc.tracks.tracks.count
        if !ChapterTOCNormalizer.isOversubdivided(tocCount: chapters.count, expectedChapterCount: trackCount) {
            return chapters
        }
        // Collapse: keep the FIRST chapter object encountered per track key.
        // This preserves the natural reading order while dropping subsections.
        var seenKeys = Set<String>()
        var collapsed: [Chapter] = []
        collapsed.reserveCapacity(trackCount)
        for chapter in chapters {
            let key = chapter.position.track.key
            if seenKeys.insert(key).inserted {
                collapsed.append(chapter)
            }
        }
        return collapsed
    }

    /// Primitive-typed mirror of `normalizedChapters(for:)` for unit-test
    /// use. Returns the expected output count given a TOC count + track
    /// count, without needing the toolkit's Chapter type.
    static func normalizedChaptersCount(tocCount: Int, trackCount: Int) -> Int {
        if !ChapterTOCNormalizer.isOversubdivided(tocCount: tocCount, expectedChapterCount: trackCount) {
            return tocCount
        }
        return trackCount
    }

    // MARK: - Position restoration helpers

    /// Logger for `[AUDIOPOS]` diagnostic lines. Indirected through a protocol
    /// so unit tests can spy on emissions without scraping Crashlytics output.
    /// Production binds the default which routes through `Log.warn`.
    var positionLogger: AudiobookPositionLogging = DefaultAudiobookPositionLogger()

    private func shouldRestoreBookmarkPosition(for book: TPPBook) -> Bool {
        let hasLocation = bookRegistry.location(forIdentifier: book.identifier) != nil
        guard hasLocation else { return false }
        return true
    }

    /// Returns a `TrackPosition` reconstructed from the registry's saved
    /// location for `book`, validated against the loaded audiobook's manifest.
    ///
    /// Failure modes are individually logged with `[AUDIOPOS]` markers. When
    /// the primary saved location can't be used but the registry has other
    /// generic bookmarks for this book, the most-recent valid one is returned
    /// as a fallback (better than dropping the patron to chapter-1 start).
    /// Returns `nil` only when there's nothing usable at all.
    private func getValidLocalPosition(book: TPPBook, audiobook: Audiobook) -> TrackPosition? {
        let primary = tryLoadPrimaryLocalPosition(book: book, audiobook: audiobook)
        switch primary {
        case .success(let position):
            return position
        case .failure:
            // Fall back to most-recent valid generic bookmark.
            if let fallback = fallbackToMostRecentValidBookmark(book: book, audiobook: audiobook) {
                positionLogger.logFallback(
                    reason: "primary_position_invalid_using_recent_bookmark",
                    context: ["bookId": book.identifier]
                )
                return fallback
            }
            return nil
        }
    }

    /// Tries to reconstruct the position from `bookRegistry.location(...)`.
    /// Each early-out logs a `[AUDIOPOS] FAIL` line so support can grep the
    /// crashlog and see exactly which step dropped the saved position.
    private func tryLoadPrimaryLocalPosition(
        book: TPPBook,
        audiobook: Audiobook
    ) -> Result<TrackPosition, AudiobookPositionValidationFailure> {
        guard let location = bookRegistry.location(forIdentifier: book.identifier) else {
            positionLogger.logFailure(reason: "no_location", context: ["bookId": book.identifier])
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        guard let dict = location.locationStringDictionary() else {
            positionLogger.logFailure(reason: "locator_decode", context: ["bookId": book.identifier])
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        guard let localBookmark = AudioBookmark.create(locatorData: dict) else {
            positionLogger.logFailure(reason: "bookmark_create", context: ["bookId": book.identifier])
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        guard let localPosition = TrackPosition(
            audioBookmark: localBookmark,
            toc: audiobook.tableOfContents.toc,
            tracks: audiobook.tableOfContents.tracks
        ) else {
            positionLogger.logFailure(
                reason: "trackposition_construct",
                context: ["bookId": book.identifier]
            )
            return .failure(.trackKeyNotInManifest(savedKey: ""))
        }
        if let failure = validationFailure(for: localPosition, in: audiobook.tableOfContents) {
            // Manifest keys for diagnostic context (first few only — avoid bloat).
            let manifestKeys = audiobook.tableOfContents.tracks.tracks
                .prefix(5).map(\.key).joined(separator: ",")
            positionLogger.logFailure(
                reason: failureReasonString(failure),
                context: [
                    "bookId": book.identifier,
                    "savedKey": localPosition.track.key,
                    "manifestKeys": manifestKeys
                ]
            )
            return .failure(failure)
        }
        return .success(localPosition)
    }

    /// Returns the most-recent valid `TrackPosition` from
    /// `bookRegistry.genericBookmarksForIdentifier(...)`, where "valid" means
    /// the validator accepts it AND it parses against the current manifest.
    /// Recency is by `lastSavedTimeStamp` (ISO8601), falling back to array
    /// order when timestamps are missing.
    private func fallbackToMostRecentValidBookmark(
        book: TPPBook,
        audiobook: Audiobook
    ) -> TrackPosition? {
        let bookmarks = bookRegistry.genericBookmarksForIdentifier(book.identifier)
        guard !bookmarks.isEmpty else { return nil }

        let candidates: [(TrackPosition, String)] = bookmarks.compactMap { location in
            guard let dict = location.locationStringDictionary(),
                  let bookmark = AudioBookmark.create(locatorData: dict),
                  let position = TrackPosition(
                    audioBookmark: bookmark,
                    toc: audiobook.tableOfContents.toc,
                    tracks: audiobook.tableOfContents.tracks
                  ),
                  validationFailure(for: position, in: audiobook.tableOfContents) == nil else {
                return nil
            }
            return (position, bookmark.lastSavedTimeStamp ?? "")
        }

        guard !candidates.isEmpty else { return nil }
        // Descending by timestamp string (ISO8601 is lexicographically sortable).
        let sorted = candidates.sorted { $0.1 > $1.1 }
        return sorted.first?.0
    }

    /// Re-uses `AudiobookPositionPolicy.validate`. The thin shim adapts the
    /// instance-level call site (which already has the toolkit's position
    /// object) to the pure-function policy (which doesn't need the toolkit).
    private func validationFailure(
        for position: TrackPosition,
        in tableOfContents: AudiobookTableOfContents
    ) -> AudiobookPositionValidationFailure? {
        let trackKeyMatches = tableOfContents.tracks.track(forKey: position.track.key) != nil
        let totalDuration = tableOfContents.tracks.totalDuration
        let positionDuration = position.durationToSelf()
        let result = AudiobookPositionPolicy.validate(
            timestamp: position.timestamp,
            positionDuration: positionDuration,
            totalDuration: totalDuration,
            trackKeyMatchesManifest: trackKeyMatches,
            savedTrackKey: position.track.key
        )
        switch result {
        case .success: return nil
        case .failure(let f): return f
        }
    }

    /// Maps a validation failure to a short greppable reason string for the
    /// `[AUDIOPOS] FAIL: <reason>` log line. Keep these stable — they're
    /// matched by support staff in crashlog triage.
    private func failureReasonString(_ failure: AudiobookPositionValidationFailure) -> String {
        switch failure {
        case .negativeTimestamp: return "negative_timestamp"
        case .nonFiniteTimestamp: return "non_finite_timestamp"
        case .trackKeyNotInManifest: return "track_key_mismatch"
        case .positionExceedsCap: return "position_exceeds_cap"
        }
    }

    /// Kept as a thin wrapper for any in-file callers that just want a bool.
    /// New code should use `validationFailure(for:in:)` directly so the
    /// failure mode can be logged.
    private func isValidPosition(_ position: TrackPosition, in tableOfContents: AudiobookTableOfContents) -> Bool {
        return validationFailure(for: position, in: tableOfContents) == nil
    }

    // MARK: - Private Methods

    /// HelpSpot 17727: Returns true when an audiobook OPEN (load) failed and the
    /// user's account is in `.credentialsStale` state (set upstream by the network
    /// layer when an authenticated request returned 401 / a recoverable auth doc),
    /// AND the account is SAML with credentials, AND there's a current book to
    /// re-open after re-auth. This is the load-path counterpart to
    /// `shouldTriggerSAMLReauthForPlaybackFailure` (PP-3703, which handles the
    /// playback-time 401 from OpenAccessPlayer).
    ///
    /// Why predicate on `authState == .credentialsStale` instead of inspecting the
    /// load error's underlying NSError: most `AudiobookLoadError` cases don't
    /// carry an HTTP-status-bearing underlying error (e.g. `manifestFetchFailed`
    /// is a bare case, no associated value). The credentials-stale signal is
    /// already propagated by `TPPNetworkResponder` / interceptors when any
    /// authenticated request returns 401, so by the time the loader returns
    /// failure we already know whether the credentials need refresh — just check
    /// the latched signal rather than try to re-derive it from a partial error.
    ///
    /// Cancellation never triggers re-auth (a superseded open shouldn't drag the
    /// user through a sign-in sheet they didn't ask for).
    static func shouldTriggerSAMLReauthForLoadFailure(
        loadError: AudiobookLoadError,
        userAccount: TPPUserAccount,
        currentBook: TPPBook?
    ) -> Bool {
        if case .cancelled = loadError {
            return false
        }
        return userAccount.authState == .credentialsStale
            && userAccount.authDefinition?.isSaml == true
            && userAccount.hasCredentials()
            && currentBook != nil
    }

    /// PP-3703: Returns true when playback failed due to bearer token refresh (e.g. 401 on CM fulfill)
    /// and the account is SAML with credentials, so we should trigger re-auth and re-open the audiobook.
    /// Extracted for unit testing to prevent regressions.
    static func shouldTriggerSAMLReauthForPlaybackFailure(error: Error?, userAccount: TPPUserAccount, currentBook: TPPBook?) -> Bool {
        let nsError = error as NSError?
        let isAuthRequired = nsError?.domain == Self.openAccessPlayerErrorDomain
            && nsError?.code == Self.openAccessPlayerErrorAuthenticationRequiredCode
        return isAuthRequired
            && userAccount.authDefinition?.isSaml == true
            && userAccount.hasCredentials()
            && currentBook != nil
    }

    private static let openAccessPlayerErrorDomain = "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer"
    private static let openAccessPlayerErrorAuthenticationRequiredCode = 5 // OpenAccessPlayerError.authenticationRequired

    private func validateRequirements(for book: TPPBook) async -> AudiobookSessionError? {
        if !(await isUserAuthenticated()) {
            return .notAuthenticated
        }

        let bookState = bookRegistry.state(for: book.identifier)
        if bookState == .unregistered || bookState == .downloadNeeded {
            return .notDownloaded
        }

        let reachability = reachabilityProvider()
        return Self.networkValidationError(
            bookState: bookState,
            isConnectedToNetwork: reachability.isConnectedToNetwork(),
            isOnWiFi: reachability.isOnWiFi,
            downloadOnlyOnWiFi: settings.downloadOnlyOnWiFi
        )
    }

    /// Pure network-rules validator. Extracted for deterministic testing against
    /// every combination of connectivity + user WiFi-only preference. The rules:
    ///   - Fully-downloaded books never need the network → no error
    ///   - Streaming books with no network at all → .networkUnavailable
    ///   - Streaming books on cellular when the user has WiFi-only enabled
    ///     → .wifiRequired (refusing to burn their cell data against their
    ///     stated preference, and surfacing the same "connect to Wi-Fi or
    ///     change settings" alert the download path uses)
    /// Builds a Crashlytics-ready NSError describing an audiobook playback
    /// failure, with all available context (typed error code, HTTP status,
    /// track URL, book id, position). Pure — straight-line unit testable
    /// without spinning up the audiobook stack. `nonisolated` because no
    /// app/state is read; lets tests call it off the MainActor.
    nonisolated static func buildPlaybackFailureRecord(error: Error?, position: TrackPosition?, bookId: String?) -> NSError {
        var userInfo: [String: Any] = [
            "bookId": bookId ?? "unknown",
            "trackTitle": position?.track.title ?? "unknown",
            "trackPosition": position.map { "\($0.timestamp)" } ?? "unknown",
        ]
        if let trackUrl = position?.track.urls?.first?.absoluteString {
            userInfo["trackUrl"] = trackUrl
        }
        if let nsError = error as NSError? {
            userInfo["underlyingDomain"] = nsError.domain
            userInfo["underlyingCode"] = nsError.code
            for (key, value) in nsError.userInfo {
                let stringKey = key as String
                guard ["httpStatusCode", "trackKey", "url"].contains(stringKey) else { continue }
                userInfo[stringKey] = value
            }
        }
        let message = "Audiobook playback failed: \(error?.localizedDescription ?? "no underlying error")"
        userInfo[NSLocalizedDescriptionKey] = message
        return NSError(
            domain: "org.thepalaceproject.palace.audiobookPlayback",
            code: (error as NSError?)?.code ?? -1,
            userInfo: userInfo
        )
    }

    /// Records the playback-failure NSError to PalaceLogging + Crashlytics
    /// non-fatal sink. Thin wrapper over `buildPlaybackFailureRecord` so the
    /// pure construction is independently testable.
    static func recordPlaybackFailure(error: Error?, position: TrackPosition?, bookId: String?) {
        let nonFatal = buildPlaybackFailureRecord(error: error, position: position, bookId: bookId)
        Log.error(#file, "Recording audiobook playback non-fatal: \(nonFatal)")
        FirebaseManager.shared.logError(nonFatal)
    }

    static func networkValidationError(
        bookState: TPPBookState,
        isConnectedToNetwork: Bool,
        isOnWiFi: Bool,
        downloadOnlyOnWiFi: Bool
    ) -> AudiobookSessionError? {
        let isFullyDownloaded = bookState == .downloadSuccessful || bookState == .used
        guard !isFullyDownloaded else { return nil }

        if !isConnectedToNetwork {
            return .networkUnavailable
        }
        if downloadOnlyOnWiFi && !isOnWiFi {
            return .wifiRequired
        }
        return nil
    }

    /// PHASE 1 (swarm_81b5099e Bucket A) — F-016 → audiobook regression fix.
    ///
    /// Previously read `account.details` directly. During the cold-launch
    /// window between `preloadAccountsFromDiskCacheSync` (synchronous, basic
    /// Account from disk) and `loadCatalogs` (async, populates the per-
    /// library `authentication_document` → `Account.details`), this returned
    /// `true` for any account whose `details` was still nil — silently
    /// pretending "no auth required" when in reality we just hadn't loaded
    /// the auth document yet. The audiobook open path then proceeded with
    /// the wrong feed-source assumption (the systemic race documented in
    /// docs/architecture/account-state-machine.md).
    ///
    /// Now blocks on `account.awaitReady()` until `Account.LoadState` is
    /// terminal (`.detailsLoaded` or `.detailsFailed`). On failure we treat
    /// the account as unauthenticated (caller maps to `.notAuthenticated`
    /// which surfaces the existing audiobook-open error UI). The existing
    /// 20s session-manager timeout is the sole timeout on this path — per
    /// the ADR's single-timeout policy we do NOT wrap awaitReady() in
    /// withTimeout here.
    private func isUserAuthenticated() async -> Bool {
        guard let account = accountsManager.currentAccount else {
            return false
        }

        let details: AccountDetails
        do {
            details = try await account.awaitReady()
        } catch {
            Log.warn(#file, "isUserAuthenticated: awaitReady failed — surfacing as notAuthenticated: \(error)")
            return false
        }

        guard let defaultAuth = details.defaultAuth else {
            return true // No auth required
        }

        if !defaultAuth.needsAuth {
            return true
        }

        return accountsManager.currentUserAccount.hasCredentials()
    }

    private func handleManagerState(_ managerState: AudiobookManagerState) {
        guard let bookId = currentBook?.identifier else { return }

        switch managerState {
        case .playbackBegan(let position):
            Log.debug(#file, "Playback began at: \(position.timestamp)")
            isPlaying = true
            hasEverStartedPlayback = true
            state = .playing(bookId: bookId)
            currentPosition = position
            updateNowPlayingInfo(position: position)
            playbackStatePublisher.send(state)

        case .playbackStopped(let position):
            Log.debug(#file, "Playback stopped at: \(position.timestamp)")
            isPlaying = false
            state = .paused(bookId: bookId)
            currentPosition = position
            nowPlayingCoordinator?.setPlaybackState(playing: false)
            playbackStatePublisher.send(state)

        case .playbackFailed(let position, let error):
            Log.error(#file, "Playback failed at position: \(String(describing: position))")
            isPlaying = false
            state = .error(bookId: bookId, message: "Playback failed")
            playbackStatePublisher.send(state)

            // Record a Crashlytics non-fatal so audiobook playback failures
            // surface in our weekly in-field signal review. Previously a
            // 403 from BiblioBoard fell through to a generic toast and
            // produced no Crashlytics record at all — the issue was
            // invisible to ops. Now every playback failure includes the
            // underlying error code, HTTP status, track URL, and book id.
            Self.recordPlaybackFailure(error: error, position: position, bookId: bookId)

            // PP-3703 (swarm_66819d80 Module C migration): When BiblioBoard
            // bearer token refresh fails due to SAML session expiration
            // (401 on CM fulfill link), the AuthCoordinator picks the
            // mechanism (SAML/OIDC modal, basic silent refresh, etc.) so
            // this site no longer carries IdP-dispatch knowledge. The
            // `shouldTriggerSAMLReauthForPlaybackFailure` boundary
            // predicate is preserved — it still gates whether we even ask
            // the coordinator (cancellations and non-SAML accounts skip
            // the entire path) — but the IdP-specific reauth (`new
            // TPPReauthenticator()` + `markCredentialsStale()`) is
            // collapsed into a single `refreshCredentialsIfNeeded` call.
            let userAccount = accountsManager.currentUserAccount
            if Self.shouldTriggerSAMLReauthForPlaybackFailure(error: error, userAccount: userAccount, currentBook: currentBook),
               let book = currentBook {
                Log.info(#file, "Playback failed with auth-required signal — dispatching through AuthCoordinator")
                let coordinator = AppContainer.production().authCoordinator
                Task { [weak self] in
                    let outcome = await coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard self.currentBook?.identifier == book.identifier else { return }
                        switch outcome {
                        case .success:
                            Log.info(#file, "Coordinator re-auth succeeded - re-fetching fulfill link and resuming audiobook")
                            Task { [weak self] in
                                guard let self else { return }
                                _ = await self.openAudiobook(book, startPlaying: true)
                            }
                        case .failure(let cancellation):
                            Log.info(#file, "Coordinator re-auth did not resume audiobook — \(cancellation)")
                            self.errorPublisher.send(.notAuthenticated)
                        }
                    }
                }
                return
            }

            errorPublisher.send(.unknown("Playback failed"))

            // Cold-load failure: playback never started for this session, so
            // the player UI is just a stuck slider showing 0:00 over a dead
            // AVPlayerItem. Dismiss the player and surface an honest "not
            // playable right now" alert — NOT a retry offer, since these
            // failures are typically persistent (distributor auth issues,
            // yanked content, etc.) and a retry button would just invite
            // rage-tapping for no outcome. If the problem was truly
            // transient the user can re-tap the book themselves; that's
            // natural UX, not a fake recovery affordance.
            if !hasEverStartedPlayback, currentBook != nil {
                Log.info(#file, "Cold-load failure detected — dismissing player UI and showing unavailable alert")
                Task { [weak self] in
                    guard let self else { return }
                    // Cold-load failure path: the player never started, so
                    // there is no meaningful "live position" to persist.
                    await self.stopPlayback(dismissPhoneUI: true, persistFinalPosition: false)
                    await MainActor.run {
                        let alert = TPPAlertUtils.alert(
                            title: NSLocalizedString("Audiobook Unavailable", comment: "Title when a cold-load playback failure dismisses the player"),
                            message: NSLocalizedString("This audiobook couldn't be played right now. The content may be temporarily unavailable — please try again later or contact your library.", comment: "Message when a cold-load playback failure dismisses the player")
                        )
                        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
                    }
                }
            }

        case .playbackCompleted(let position):
            Log.info(#file, "Playback completed at: \(position.timestamp)")
            isPlaying = false
            state = .paused(bookId: bookId)
            currentPosition = position
            playbackStatePublisher.send(state)

        case .positionUpdated(let position):
            if let position = position {
                handlePositionUpdate(position)
            }

        default:
            break
        }
    }

    private func handlePositionUpdate(_ position: TrackPosition) {
        currentPosition = position

        // Check for chapter change using manager's currentChapter.
        // Decision delegated to ChapterChangeDetector — was previously an OR
        // over `key != key || title != title`, which fired spuriously for
        // anthology audiobooks whose adjacent same-track chapters share a
        // title. The new policy keys on track-key change only; same-key /
        // different-title pairs do NOT count as a chapter crossing.
        if let mgr = manager, let newChapter = mgr.currentChapter {
            if ChapterChangeDetector.didChange(
                oldKey: currentChapter?.position.track.key,
                oldTitle: currentChapter?.title,
                newKey: newChapter.position.track.key,
                newTitle: newChapter.title
            ) {
                currentChapter = newChapter
                chapterUpdatePublisher.send((chapters: currentChapters, current: currentChapter))
                Log.debug(#file, "Chapter changed to: '\(newChapter.title)'")
            }
        }

        // Update Now Playing (debounced in coordinator)
        updateNowPlayingInfo(position: position)
    }

    private func updateNowPlayingInfo(position: TrackPosition) {
        guard let book = currentBook,
              let audiobook = audiobook,
              let mgr = manager else {
            return
        }

        // Use manager's public properties for chapter info
        let chapter = mgr.currentChapter
        let chapterOffset = mgr.currentOffset
        let chapterDuration = mgr.currentDuration

        let title = chapter?.title ?? position.track.title ?? "Unknown"

        nowPlayingCoordinator?.updateNowPlaying(
            title: title,
            artist: book.title,
            album: book.authors,
            elapsed: chapterOffset,
            duration: chapterDuration,
            isPlaying: isPlaying,
            playbackRate: audiobook.player.playbackRate
        )
    }
}
