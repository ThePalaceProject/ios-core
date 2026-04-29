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

    // MARK: - Singleton

    public static let shared = AudiobookSessionManager()

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

    // MARK: - Initialization

    /// Designated init — every dependency is explicit. `private` so the
    /// singleton accessor remains the only entry point in production.
    private init(
        bookRegistry: TPPBookRegistryProvider,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        reachabilityProvider: @escaping () -> Reachability,
        bookCoverRegistryProvider: @escaping () -> TPPBookCoverRegistry,
        navigationCoordinatorHubProvider: @escaping () -> NavigationCoordinatorHub
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.settings = settings
        self.reachabilityProvider = reachabilityProvider
        self.bookCoverRegistryProvider = bookCoverRegistryProvider
        self.navigationCoordinatorHubProvider = navigationCoordinatorHubProvider
        Log.info(#file, "AudiobookSessionManager initialized")
        nowPlayingCoordinator = NowPlayingCoordinator()
        // Note: Remote commands are handled by the toolkit's MediaControlPublisher.
        // This manager now owns the full audiobook lifecycle (load → bind → play)
        // directly via AudiobookLoader; no pub/sub handoff is needed.
        subscribeToPhoneSideErrorAlerts()
    }

    /// Backwards-compatible convenience for the singleton. Resolves every
    /// dependency from `.shared` accessors at the moment the singleton is
    /// first touched. Production code should prefer
    /// `init(appContainer:)` so the dep graph is explicit.
    private convenience init() {
        self.init(
            bookRegistry: TPPBookRegistry.shared,
            accountsManager: AppContainer.production().accountsManager,
            settings: AppContainer.production().settings,
            reachabilityProvider: { AppContainer.production().reachability },
            bookCoverRegistryProvider: { TPPBookCoverRegistry.shared },
            navigationCoordinatorHubProvider: { AppContainer.production().navigationCoordinatorHub }
        )
    }

    /// AppContainer-friendly initializer. Used by future call sites that
    /// thread the container down to here. Provider closures default to
    /// `.shared` accessors since AppContainer doesn't currently hold
    /// Reachability / TPPBookCoverRegistry / NavigationCoordinatorHub.
    convenience init(
        appContainer: AppContainer,
        reachabilityProvider: @escaping () -> Reachability = { AppContainer.production().reachability },
        bookCoverRegistryProvider: @escaping () -> TPPBookCoverRegistry = { TPPBookCoverRegistry.shared },
        navigationCoordinatorHubProvider: @escaping () -> NavigationCoordinatorHub = { AppContainer.production().navigationCoordinatorHub }
    ) {
        self.init(
            bookRegistry: appContainer.bookRegistry,
            accountsManager: appContainer.accountsManager,
            settings: appContainer.settings,
            reachabilityProvider: reachabilityProvider,
            bookCoverRegistryProvider: bookCoverRegistryProvider,
            navigationCoordinatorHubProvider: navigationCoordinatorHubProvider
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
            await stopPlayback(dismissPhoneUI: !isSameBook)
        }

        if let error = validateRequirements(for: book) {
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
        manager.audiobook.player.play(at: chapter.position, completion: nil)

        Log.debug(#file, "Skipping to chapter: '\(chapter.title)'")
    }

    /// Cycles through playback rates
    public func cyclePlaybackRate() -> PlaybackRate {
        guard let player = manager?.audiobook.player else {
            return .normalTime
        }

        let rates: [PlaybackRate] = [.threeQuartersTime, .normalTime, .oneAndAQuarterTime, .oneAndAHalfTime, .doubleTime]
        let currentIndex = rates.firstIndex(of: player.playbackRate) ?? 1
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
    /// - Parameter dismissPhoneUI: Whether to dismiss the player UI on the phone (default: true)
    public func stopPlayback(dismissPhoneUI: Bool = true) async {
        Log.info(#file, "Stopping playback (dismissPhoneUI: \(dismissPhoneUI))")

        // Cancel any in-flight loader so its completion is ignored.
        currentLoader?.cancel()
        currentLoader = nil

        let bookId = currentBook?.identifier

        // Prefer the live position from the player over the cached value, which
        // may lag behind if the user scrubbed or the position update hadn't fired yet.
        let livePosition = manager?.audiobook.player.currentTrackPosition ?? currentPosition
        if let position = livePosition {
            manager?.saveLocation(position)
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
        self.currentChapters = loaded.audiobook.tableOfContents.toc

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

        Task { @MainActor in
            loaded.playbackModel.currentLocation = initialPosition
            loaded.playbackModel.beginSaveSuppression(for: 3.0)
            loaded.manager.audiobook.player.play(at: initialPosition) { error in
                if let error = error {
                    Log.error(#file, "Playback start error: \(error)")
                } else {
                    Log.info(#file, "🎵 Playback started at initial position")
                }
            }
        }

        let bookId = book.identifier
        let audiobookRef = loaded.audiobook
        let playbackModelRef = loaded.playbackModel
        // `syncLocation(for:)` lives on the concrete TPPBookRegistry as an
        // extension; the provider protocol doesn't expose it. Cast at the
        // call site so the rest of this file talks to the protocol.
        let concreteRegistry = (bookRegistry as? TPPBookRegistry) ?? TPPBookRegistry.shared
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
                currentMgr.audiobook.player.play(at: remote) { error in
                    if let error = error {
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

    // MARK: - Position restoration helpers

    private func shouldRestoreBookmarkPosition(for book: TPPBook) -> Bool {
        let hasLocation = bookRegistry.location(forIdentifier: book.identifier) != nil
        guard hasLocation else { return false }
        return true
    }

    private func getValidLocalPosition(book: TPPBook, audiobook: Audiobook) -> TrackPosition? {
        guard let dict = bookRegistry.location(forIdentifier: book.identifier)?.locationStringDictionary(),
              let localBookmark = AudioBookmark.create(locatorData: dict),
              let localPosition = TrackPosition(
                audioBookmark: localBookmark,
                toc: audiobook.tableOfContents.toc,
                tracks: audiobook.tableOfContents.tracks
              ),
              isValidPosition(localPosition, in: audiobook.tableOfContents) else {
            return nil
        }
        return localPosition
    }

    private func isValidPosition(_ position: TrackPosition, in tableOfContents: AudiobookTableOfContents) -> Bool {
        guard position.timestamp >= 0 && position.timestamp.isFinite else { return false }
        guard tableOfContents.tracks.track(forKey: position.track.key) != nil else { return false }
        let totalDuration = tableOfContents.tracks.totalDuration
        if totalDuration <= 0 { return true }
        let positionDuration = position.durationToSelf()
        if positionDuration > totalDuration * 1.1 { return false }
        return true
    }

    // MARK: - Private Methods

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

    private func validateRequirements(for book: TPPBook) -> AudiobookSessionError? {
        if !isUserAuthenticated() {
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

    private func isUserAuthenticated() -> Bool {
        guard let account = accountsManager.currentAccount else {
            return false
        }

        guard let details = account.details,
              let defaultAuth = details.defaultAuth else {
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

            // PP-3703: When BiblioBoard bearer token refresh fails due to SAML session expiration
            // (401 on CM fulfill link), trigger SAML re-login and then re-fetch fulfill to resume playback.
            let userAccount = accountsManager.currentUserAccount
            if Self.shouldTriggerSAMLReauthForPlaybackFailure(error: error, userAccount: userAccount, currentBook: currentBook),
               let book = currentBook {
                Log.info(#file, "SAML + BiblioBoard: Bearer token refresh failed (session expired) - triggering re-auth, will re-open audiobook after login")
                userAccount.markCredentialsStale()
                let reauthenticator = TPPReauthenticator()
                reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true) { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.currentBook?.identifier == book.identifier else { return }
                        guard self.accountsManager.currentUserAccount.hasCredentials() else {
                            Log.info(#file, "SAML re-auth cancelled or failed - not re-opening audiobook")
                            self.errorPublisher.send(.notAuthenticated)
                            return
                        }
                        Log.info(#file, "SAML re-auth succeeded - re-fetching fulfill link and resuming audiobook")
                        _ = await self.openAudiobook(book, startPlaying: true)
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
                    await self.stopPlayback(dismissPhoneUI: true)
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

        // Check for chapter change using manager's currentChapter
        if let mgr = manager, let newChapter = mgr.currentChapter {
            if currentChapter?.position.track.key != newChapter.position.track.key ||
                currentChapter?.title != newChapter.title {
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
