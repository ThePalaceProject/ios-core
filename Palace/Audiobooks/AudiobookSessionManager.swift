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
///
/// **Account-switch contract for the playtimes tracker (Bug B, swarm_162a3219).**
///
/// On `AccountsManager.currentAccount.didSet`, the manager calls
/// `cleanupActiveContentBeforeAccountSwitch(...)` which fires
/// `networkExecutor.cancelNonEssentialTasks()` to kill any in-flight
/// playtimes POSTs and posts `.TPPCurrentAccountDidChange`. The
/// per-book `AudiobookTimeTracker` is per-library-by-construction (its
/// `libraryId` is captured at init), but the `AudiobookDataManager`
/// queue is process-wide: it holds entries for every library the user
/// has played from since the last successful sync.
///
/// `AudiobookDataManager.syncValues()` carries the cross-account scope
/// guard: each queued entry is compared against
/// `currentAccountIdProvider()` and uploads for non-matching libraries
/// are SKIPPED. The skipped entries stay in the queue and flush when
/// the user switches back. The session manager itself takes no
/// additional action on account switch — the tracker contract owns
/// the upload-side scoping. See
/// `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md`
/// §2 Bug B for the regression history.
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
    ///
    /// Note (swarm_0b7616e7 Module C): on develop's base this is consumed by
    /// `dismissPlayerOnPhone(bookId:)` and `presentCoverArtAndNavigation(...)`
    /// for the `pushAudioRoute` / `removeAudioModel` / `popToRoot` calls.
    /// After this contract lands those calls move to the presenter, but the
    /// hub provider stays alive for legacy compat (per §6.2 point 3 — the
    /// NavigationCoordinator audio-route surface remains until a follow-up
    /// swarm removes it).
    private let navigationCoordinatorHubProvider: () -> NavigationCoordinatorHub

    /// Resolves the root-level audiobook session presenter. Set via the
    /// AppContainer convenience init (`audiobookSessionPresenterProvider`
    /// closure parameter) — production default routes through
    /// `AppContainer.production().audiobookSessionPresenter` so the
    /// process-wide cached presenter is reused; tests pass a closure
    /// returning a spy presenter so the migration tests can assert on
    /// `presentOnFirstOpen()` / `adoptBook(_:)` / `adoptPlaybackModel(_:)`
    /// / `clearActiveSession()` calls without touching AppContainer.
    ///
    /// `@MainActor` on the closure type so callers can reach
    /// `AppContainer.production().audiobookSessionPresenter` (which is
    /// `@MainActor`-isolated) from the default factory without a Swift
    /// 6 isolation error.
    ///
    /// swarm_0b7616e7 Module C — replaces the legacy
    /// `coordinator.storeAudioModel + coordinator.pushAudioRoute` pair at
    /// develop lines 647-654 + `coordinator.removeAudioModel +
    /// coordinator.popToRoot` pair at develop lines 560-566.
    private let audiobookSessionPresenterProvider: @MainActor () -> AudiobookSessionPresenter

    /// Resolves whether the in-app-playback-nav feature is enabled. Gates
    /// which presentation `presentSession` drives: off → the legacy
    /// full-screen pushed `.audio` route; on → the root-level presenter
    /// (mini-player + full-player overlay). Production default reads
    /// `RemoteFeatureFlags.shared`; tests inject a fixed value so the
    /// flag-branch decision is exercised without touching UserDefaults.
    private let inAppPlaybackNavEnabledProvider: () -> Bool

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
        audiobookSessionPresenterProvider: @escaping @MainActor () -> AudiobookSessionPresenter,
        inAppPlaybackNavEnabledProvider: @escaping () -> Bool,
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
        self.audiobookSessionPresenterProvider = audiobookSessionPresenterProvider
        self.inAppPlaybackNavEnabledProvider = inAppPlaybackNavEnabledProvider
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
        audiobookSessionPresenterProvider: @escaping @MainActor () -> AudiobookSessionPresenter = { AppContainer.production().audiobookSessionPresenter },
        inAppPlaybackNavEnabledProvider: @escaping () -> Bool = { RemoteFeatureFlags.shared.isInAppPlaybackNavEnabled },
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
            audiobookSessionPresenterProvider: audiobookSessionPresenterProvider,
            inAppPlaybackNavEnabledProvider: inAppPlaybackNavEnabledProvider,
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
    /// Protocol witness (`AudiobookSessionManaging`): a normal user-initiated
    /// open. Delegates to the `forceRefulfill` body with re-fulfill off.
    @discardableResult
    public func openAudiobook(_ book: TPPBook, startPlaying: Bool = true) async -> Result<Void, AudiobookSessionError> {
        await openAudiobook(book, startPlaying: startPlaying, forceRefulfill: false)
    }

    /// WS-3: per-session bound on the OverDrive expired-URL re-fulfill recovery.
    /// A book id is inserted when its recovery re-open fires and removed when the
    /// user initiates a fresh open — so a persistent failure re-fulfills at most
    /// ONCE per playback session and never loops on the shared handler.
    private var overdriveRefulfillAttemptedBookIds = Set<String>()

    /// PP-4542: per-session bound on the cold-load auto-reopen recovery. A book
    /// id is inserted when its automatic re-open fires and removed when the user
    /// initiates a fresh open — so a cold-load failure auto-reopens at most ONCE
    /// per playback session and a genuinely persistent failure surfaces the
    /// "Audiobook Unavailable" alert instead of looping. Visibility is internal
    /// (not private) so the cold-load recovery test can assert the bound.
    var coldLoadReopenAttemptedBookIds = Set<String>()

    /// PP-4542 (A): book ids currently parked in the "awaiting content download"
    /// recovery (a fresh-borrow streaming failure whose `.lcpa` hasn't landed
    /// yet). The streaming player emits a *storm* of `.playbackFailed` events for
    /// a single failed open; without this guard, the first failure enters the
    /// await branch but the next one — now seeing `alreadyAttempted == true` —
    /// falls straight through to the "Unavailable" alert, defeating the wait.
    /// While a book id is in this set, further `.playbackFailed` events for it
    /// are swallowed until the await resolves (content lands → reopen, or times
    /// out → alert). Internal so the recovery test can assert the guard.
    var awaitingContentDownloadBookIds = Set<String>()

    /// Loader factory — recovery seam (WS-3). The default closure is
    /// byte-equivalent to the inline `AudiobookLoader(forceRefulfill:)` it
    /// replaces, so production behavior is unchanged. `private(set)` so only
    /// this type rewires it — no in-module production path can overwrite the
    /// factory. The fresh-URL-consumed behavior it enables is proven at the
    /// `AudiobookLoader(adapters:)` boundary, not by reassigning this seam.
    private(set) var makeLoader: (Bool) -> AudiobookLoader = { AudiobookLoader(forceRefulfill: $0) }

    /// - parameter forceRefulfill: WS-3 OverDrive recovery — when true the loader
    ///   bypasses `LocalFileAdapter` so the book re-fulfills FRESH signed URLs
    ///   instead of replaying the expired on-disk manifest. Internal (not part of
    ///   the public `AudiobookSessionManaging` surface); the public 2-param
    ///   witness above delegates here, and the in-class recovery branch calls it.
    func openAudiobook(_ book: TPPBook, startPlaying: Bool, forceRefulfill: Bool, isColdLoadRecovery: Bool = false) async -> Result<Void, AudiobookSessionError> {
        Log.info(#file, "Opening audiobook: '\(book.title)' (id: \(book.identifier))\(forceRefulfill ? " [re-fulfill]" : "")\(isColdLoadRecovery ? " [cold-load recovery]" : "")")
        // Polish-phase (in-app-nav-polish-2026-06-01): record wall-clock
        // open time so the Continue Reading row's sort surfaces the real
        // last-touched book even when the audiobook position-save flow
        // hasn't yet written its first timeStamp. Idempotent overwrite.
        AppContainer.production().bookOpenTracker.recordOpened(book.identifier)

        // A fresh user-initiated open resets the per-session re-fulfill bound so
        // a later genuine expiry can recover again; the recovery re-open
        // (forceRefulfill) must NOT reset it, or the bound never holds.
        if !forceRefulfill {
            overdriveRefulfillAttemptedBookIds.remove(book.identifier)
            // The cold-load recovery re-open must NOT reset its own bound, or the
            // one-shot guard never holds and a persistently-failing book loops
            // (re-open → fail → re-open …). Mirrors the OverDrive forceRefulfill
            // guard. PP-4542.
            if !isColdLoadRecovery {
                coldLoadReopenAttemptedBookIds.remove(book.identifier)
            }
        }

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

#if LCP
        // PP-4542 (gate): a freshly-borrowed LCP audiobook is marked
        // download-successful the instant its tiny .lcpl license lands, but the
        // real .lcpa content is still downloading in the background. Opening now
        // would route through the streaming path — and LCP streaming-from-
        // license is BROKEN under Readium 3.9.0: the remote read returns 0 bytes
        // with nil length, so AVPlayer dead-ends in CoreMedia -12873 → -11849
        // "Operation Stopped" (the 3.2.0-only "Audiobook Unavailable"; confirmed
        // via instrumented repro). The content download is already in flight, so
        // instead of attempting the broken stream we HOLD the loading state and
        // open from the local package the moment it lands — the reliable path.
        // Skipped for cold-load recovery re-opens (content is already local by
        // then). Generation/identity re-checked after the wait so a newer open
        // supersedes us cleanly.
        if !isColdLoadRecovery,
           LCPAudiobooks.canOpenBook(book),
           !Self.audiobookContentIsLocal(book.identifier) {
            Log.info(#file, "LCP audiobook content still downloading — awaiting local package before opening (PP-4542 gate)")
            let landed = await Self.awaitAudiobookContentLocal(book.identifier)
            // A newer open (user tapped a different book) would have replaced
            // currentBook + the .loading state; bail if so.
            guard currentBook?.identifier == book.identifier,
                  case .loading(let lid) = state, lid == book.identifier else {
                Log.info(#file, "PP-4542 gate: a newer open superseded \(book.identifier) while awaiting content — bailing")
                return .failure(.alreadyLoading)
            }
            if !landed {
                Log.info(#file, "PP-4542 gate: content did not finish downloading within the wait window — surfacing unavailable")
                await dismissAndPresentColdLoadUnavailable()
                return .failure(.unknown("Audiobook content is still downloading"))
            }
            Log.info(#file, "PP-4542 gate: content landed — opening '\(book.title)' from local package")
        }
#endif

        // PP-4542 follow-up: activate the audio session NOW, while the book
        // loads, so it's live by the time the toolkit issues the first play().
        // Cold launch defers session activation (it ran only on CarPlay connect /
        // foreground re-entry), so a plain first open issued play() against an
        // inactive session → AVError -11849 ("Operation Stopped") → slow start via
        // auto-reopen. Pre-existing (also on 3.1.0); this removes the slow start.
        AppContainer.production().playbackBootstrapper.ensureAudioSessionActiveForPlayback()

        loadGeneration &+= 1
        let generation = loadGeneration
        let loader = makeLoader(forceRefulfill)
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
                        // Publish the terminal `.error` so the session presenter
                        // (mini-player + full-player overlay) tears down. Without
                        // this the presenter never sees the failure and the chrome
                        // lingers in its last-published `.loading` look.
                        self.playbackStatePublisher.send(self.state)
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
        publishPlaybackStateChange(isPlaying: true)
    }

    /// Pauses the current audiobook
    public func pause() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot pause - no active manager")
            return
        }

        manager.pause()
        nowPlayingCoordinator?.setPlaybackState(playing: false)
        publishPlaybackStateChange(isPlaying: false)
    }

    /// Toggles play/pause
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Polish-phase reactivity fix (in-app-nav-polish-2026-06-01).
    /// Updates the manager's published `state` AND fires
    /// `playbackStatePublisher` so the presenter's `@Published isPlaying`
    /// mirror flips reactively, driving the mini-player + full-player
    /// glyph updates and the CarPlay bridge.
    ///
    /// Pre-polish: `play()` / `pause()` updated only the Now Playing
    /// center; the publisher never fired on user-initiated play/pause —
    /// the mini-player glyph stayed stuck on the pre-tap value, which
    /// the user reported as "none of the buttons work."
    private func publishPlaybackStateChange(isPlaying: Bool) {
        guard let bookId = currentBook?.identifier else { return }
        let newState: AudiobookSessionState = isPlaying
            ? .playing(bookId: bookId)
            : .paused(bookId: bookId)
        state = newState
        playbackStatePublisher.send(newState)
    }

    /// Polish-phase background-freeze recovery
    /// (in-app-nav-polish-2026-06-01). Called from
    /// `AudiobookSessionPresenter.subscribeToAppLifecycle` on
    /// `UIApplication.willEnterForegroundNotification` when there's an
    /// active session.
    ///
    /// Strategy:
    ///   1. Re-activate the audio session via PlaybackBootstrapper so a
    ///      transient background-time deactivation doesn't leave AVPlayer
    ///      starved.
    ///   2. If the manager believes playback was in flight (state was
    ///      `.playing` when we backgrounded), call `play()` to nudge the
    ///      toolkit's player out of any stalled buffer-empty state. This
    ///      is the operative recovery: AVPlayer re-fetches its buffer and
    ///      `Player.isLoaded` re-flips to true, dismissing the toolkit's
    ///      LoadingView before the 30s `LoadingErrorView` timer fires.
    public func recoverPlaybackForForegroundEntry() {
        guard let _ = manager else { return }
        // Re-prime the audio session — bootstrapper's ensureInitialized is
        // idempotent and re-activates AVAudioSession if it had been
        // deactivated. AudiobookSessionManager doesn't hold an `appContainer`
        // reference (its convenience init pulls deps off the production
        // container and stores them as separate fields), so we reach the
        // bootstrapper directly via the cached production accessor — same
        // pattern other recovery paths use (e.g.,
        // `navigationCoordinatorHubProvider` default).
        AppContainer.production().playbackBootstrapper.ensureInitialized()
        if case .playing = state {
            // Was playing pre-background; ask the toolkit to resume.
            // `manager.play()` is idempotent.
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

    /// Default skip interval (seconds) used by `skipBack()` / `skipForward()`.
    /// Palace standardizes on 30s in both directions to match the SF Symbols
    /// `gobackward.30` / `goforward.30` glyphs the mini-player + full player
    /// chrome render. Exposed `internal static` so the polish-phase mini-
    /// player tests can pin the value without dragging the toolkit's
    /// `DefaultAudiobookManager.skipTimeInterval` (which is `internal`) into
    /// the assertion.
    static let defaultSkipInterval: TimeInterval = 30

    /// Skips the playhead backward by `defaultSkipInterval` seconds.
    /// Wraps the toolkit's `Player.skipPlayhead(_:)` async signature
    /// (`Player.swift:108`) in a `Task { @MainActor in ... }` boundary so the
    /// sync `AudiobookSessionManaging` protocol surface stays simple — same
    /// async→sync pattern as `skipToChapter(at:)` at lines 524-528. The
    /// async result (resulting `TrackPosition?`) is intentionally discarded
    /// because the toolkit fires its own `positionPublisher` updates which
    /// the presenter mirrors via `playbackModel.$currentLocation`.
    ///
    /// in-app-nav-polish-2026-06-01 — added so the root-level mini-player
    /// chrome can drive 30s rewind without reaching for the toolkit type
    /// directly (`AudiobookPlaybackModel.audiobookManager` is internal-only).
    public func skipBack() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot skipBack — no active manager")
            return
        }
        Task { @MainActor in
            _ = await manager.audiobook.player.skipPlayhead(-Self.defaultSkipInterval)
        }
        Log.debug(#file, "Skipping back \(Self.defaultSkipInterval)s")
    }

    /// Skips the playhead forward by `defaultSkipInterval` seconds. See
    /// `skipBack()` for the async-boundary rationale.
    public func skipForward() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot skipForward — no active manager")
            return
        }
        Task { @MainActor in
            _ = await manager.audiobook.player.skipPlayhead(Self.defaultSkipInterval)
        }
        Log.debug(#file, "Skipping forward \(Self.defaultSkipInterval)s")
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

        // 3.2.3 Cause 2: cancel any pending throttled remote listening-position
        // write BEFORE tearing down the manager, so a queued snapshot can't
        // flush after teardown and resurrect a stale server position. Must run
        // while `manager?.bookmarkDelegate` (the writer's owner) is still live.
        if let bookId {
            await cancelPendingRemotePositionWrite(forBookId: bookId)
        }

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

    /// 3.2.3 Cause 2 wiring. Cancels any pending throttled remote
    /// listening-position write for `bookId` by routing to the live bookmark
    /// delegate (`AudiobookBookmarkBusinessLogic`) that owns the
    /// `RemotePositionWriter`. Only cancels when `bookId` is the active
    /// session's book (a queued write can only exist for the book whose
    /// delegate is currently bound); a no-op otherwise. This is the single
    /// implementation used by both `stopPlayback` (self) and the
    /// `BookReturnService` return path (via the `AudiobookSessionManaging`
    /// protocol on `AppContainer.audiobookSession`).
    @MainActor
    public func cancelPendingRemotePositionWrite(forBookId bookId: String) async {
        guard let logic = manager?.bookmarkDelegate as? AudiobookBookmarkBusinessLogic,
              logic.book.identifier == bookId else {
            return
        }
        await logic.cancelPendingRemotePositionWrite()
    }

    /// Dismisses the audiobook player view on the phone.
    ///
    /// Mirrors the flag-gated presentation in `presentSession`: the dismiss
    /// must undo whatever the present path did.
    ///   - Flag ON: the presenter owns the player chrome (mini-player + root
    ///     overlay), so clearing it IS the dismiss. No nav stack is touched —
    ///     `popToRoot` would wipe whatever non-audio route the user had pushed
    ///     (book detail, settings subview), violating PP-3783's "back-stack
    ///     preserved" UX.
    ///   - Flag OFF: the player was pushed as an `.audio` route, so the
    ///     dismiss pops that route and drops the cached model. `pop()` (not
    ///     `popToRoot()`) removes only the top `.audio` route, preserving any
    ///     underlying non-audio route per PP-3783.
    ///
    /// `internal` so `@testable import Palace` tests can drive either branch
    /// directly without going through the full `stopPlayback` lifecycle
    /// (which would also tear down the toolkit manager — requiring a
    /// fully-stubbed `AudiobookManager`).
    @MainActor
    internal func dismissPlayerOnPhone(bookId: String) {
        Log.info(#file, "Dismissing player UI on phone for book: \(bookId)")
        if inAppPlaybackNavEnabledProvider() {
            audiobookSessionPresenterProvider().clearActiveSession()
        } else if let coordinator = navigationCoordinatorHubProvider().coordinator {
            coordinator.removeAudioModel(forBookId: bookId)
            // PP-4542: only pop if the audio player is actually on top. A stale
            // unconditional pop here removed the NEW book's detail when tearing
            // down a previous session whose player had already been navigated
            // away — dumping the user on the catalog for the whole download-gate.
            coordinator.popIfTopRouteAudio()
        }
    }

    /// Updates cover image (called when image loads asynchronously).
    ///
    /// Forwards to the root-level presenter so the mini-player + full player
    /// chrome see the new image without polling. Async hi-res replacements
    /// arrive AFTER the initial `adoptPlaybackModel(_:)` snapshot (lo-res
    /// sync, hi-res via the `loadCoverArt(for:into:)` Task) — without this
    /// forward, the presenter's `coverImage` would stay at lo-res for the
    /// rest of the session even though `sessionManager.coverImage` got
    /// upgraded. in-app-nav-polish-2026-06-01.
    public func updateCoverImage(_ image: UIImage?) {
        coverImage = image
        nowPlayingCoordinator?.updateArtwork(image)
        audiobookSessionPresenterProvider().adoptCoverImage(image)
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
        loadCoverArt(for: book, into: loaded.playbackModel)
        presentSession(book: book, playbackModel: loaded.playbackModel)
    }

    /// Flag-gated presentation decision. The in-app-nav feature only changes
    /// how the player is presented when `in_app_playback_nav_enabled` is on:
    /// off → the original full-screen pushed `.audio` route; on → the
    /// root-level presenter (mini-player + full-player overlay).
    ///
    /// `internal` so the migration tests can drive each branch with a spy
    /// coordinator hub (off) or spy presenter (on) without owning a
    /// `LoadedAudiobook`. `playbackModel` is optional for the same reason as
    /// `pushSessionToPresenter` — production passes the loaded model, tests
    /// pass nil. In production the model is always present, so the off-branch
    /// `storeAudioModel` always runs.
    @MainActor
    internal func presentSession(book: TPPBook, playbackModel: AudiobookPlaybackModel?) {
        if inAppPlaybackNavEnabledProvider() {
            pushSessionToPresenter(book: book, playbackModel: playbackModel)
        } else {
            let route = BookRoute(id: book.identifier)
            if let coordinator = navigationCoordinatorHubProvider().coordinator {
                if let playbackModel = playbackModel {
                    coordinator.storeAudioModel(playbackModel, forBookId: route.id)
                }
                coordinator.pushAudioRoute(route)
            } else {
                Log.info(#file, "No navigation coordinator (CarPlay background launch?) — playback will start without phone UI")
            }
        }
    }

    /// Loads cover art into the playback model — both the low-res cached
    /// copy (synchronous) and the high-res registry copy (async). Split
    /// from `presentCoverArtAndNavigation` so the presenter-side call
    /// can be driven independently from tests without constructing a full
    /// `LoadedAudiobook` shape.
    private func loadCoverArt(for book: TPPBook, into playbackModel: AudiobookPlaybackModel) {
        if let lowRes = book.coverImage ?? book.thumbnailImage {
            playbackModel.updateCoverImage(lowRes)
            updateCoverImage(lowRes)
        }
        let coverRegistry = bookCoverRegistryProvider()
        Task { [weak self, weak playbackModel] in
            guard let img = await coverRegistry.coverImage(for: book) else { return }
            await MainActor.run {
                playbackModel?.updateCoverImageAnimated(img)
                self?.updateCoverImage(img)
            }
        }
    }

    /// Drives the root-level presenter on a fresh open.
    ///
    /// The legacy `coordinator.storeAudioModel + pushAudioRoute` pair is
    /// gone; the mini-player + fullScreenCover Module D wires into
    /// AppTabHostView render off the presenter's `playbackModel` +
    /// `currentBook` + `isPlayerExpanded` published values.
    ///
    /// F-011 preservation (§7.4): `presentOnFirstOpen()` is called
    /// SYNCHRONOUSLY here, BEFORE the readiness-gate Task in
    /// `startPlaybackAndSyncPosition` runs (`bind` calls
    /// `presentCoverArtAndNavigation` → `pushSessionToPresenter` first,
    /// then `startPlaybackAndSyncPosition`). This means the full player
    /// is expanded showing cover art + loading state while the readiness
    /// gate awaits — pre-presenter behavior was driven by
    /// `pushAudioRoute`'s NavigationStack push, which had the same
    /// synchronous-before-the-Task ordering.
    ///
    /// `internal` so `@testable import Palace` migration tests can drive
    /// the presenter-side branch directly with a spy presenter via the
    /// `audiobookSessionPresenterProvider` closure. The function is the
    /// production seam — what `presentCoverArtAndNavigation` calls — so
    /// driving it directly is honest end-state coverage of the migrated
    /// behavior.
    ///
    /// `playbackModel` is optional: production callers pass the loaded
    /// model; migration tests pass nil because the toolkit's
    /// `AudiobookPlaybackModel(audiobookManager:)` requires a full
    /// `Audiobook` + `Manifest` graph that's impractical to construct
    /// from XCTest. The presenter records the calls regardless; absence
    /// of a real model in the test does not weaken the migration
    /// assertion.
    @MainActor
    internal func pushSessionToPresenter(book: TPPBook, playbackModel: AudiobookPlaybackModel?) {
        let presenter = audiobookSessionPresenterProvider()
        presenter.adoptBook(book)
        if let playbackModel = playbackModel {
            presenter.adoptPlaybackModel(playbackModel)
        }
        presenter.presentOnFirstOpen()
        Log.debug(#file, "Presenting audiobook session via root presenter for \(book.identifier)")
    }

    private func startPlaybackAndSyncPosition(for book: TPPBook, loaded: LoadedAudiobook) {
        guard let firstTrack = loaded.audiobook.tableOfContents.allTracks.first else {
            Log.error(#file, "No tracks available in audiobook")
            return
        }
        let shouldRestore = shouldRestoreBookmarkPosition(for: book)
        let localPosition = shouldRestore ? getValidLocalPosition(book: book, audiobook: loaded.audiobook) : nil
        let beginning = TrackPosition(
            track: firstTrack,
            timestamp: 0.0,
            tracks: loaded.audiobook.tableOfContents.tracks
        )
        let bookId = book.identifier

        // PP-4542 launch-smoothing: resolve the position to OPEN at — preferring a
        // newer REMOTE bookmark over the local one — BEFORE issuing the first
        // play, so playback opens directly at the right spot. Previously play
        // started at the local/0 position immediately and the async server-bookmark
        // sync then seeked to the remote position a beat later, which the user saw
        // as the playhead "jumping around" before settling. The remote lookup is
        // bounded (`remotePositionResolveTimeout`) so a slow/again backend can't
        // stall open — on timeout we open at the local/beginning position
        // (bookmarks normally return in ~0.5s, so the timeout is a rare safety
        // valve, not the common path).
        Task { @MainActor in
            guard self.currentBook?.identifier == bookId else { return }
            let initialPosition = await self.resolveInitialPosition(
                for: book,
                audiobook: loaded.audiobook,
                localPosition: localPosition,
                fallback: localPosition ?? beginning
            )
            guard self.currentBook?.identifier == bookId else { return }
            self.issueFirstPlay(for: book, loaded: loaded, initialPosition: initialPosition)
        }
    }

    /// Issues the first `play(at:)` for a freshly-loaded audiobook at the
    /// already-resolved `initialPosition` (see the resolve step in
    /// `startPlaybackAndSyncPosition`). Extracted so the position resolve can run
    /// — and be awaited — BEFORE play, without disturbing the F-011 readiness-gate
    /// / LCP-bypass wiring below.
    @MainActor
    private func issueFirstPlay(for book: TPPBook, loaded: LoadedAudiobook, initialPosition: TrackPosition) {
        Log.debug(#file, "Opening '\(book.title)' at: track=\(initialPosition.track.key), timestamp=\(initialPosition.timestamp)")

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
                // LCP can't use the await-then-play gate (isLoaded only flips
                // AFTER play → the gate would deadlock; see the bypass rationale
                // above). That left LCP on the ORIGINAL single fire-and-forget
                // play that drops silently when the engine is still initializing
                // on first-open (F-011: UI mounted, no audio; nav-away-and-back
                // works because it re-issues play after init). Reliable start =
                // play-then-confirm-with-bounded-retry (WS-5).
                await self.confirmLCPFirstPlay(
                    bookId: bookId,
                    initialPosition: initialPosition,
                    probe: probe,
                    command: command,
                    budget: Self.lcpFirstPlayBudget,
                    retryInterval: Self.lcpFirstPlayRetryInterval
                )
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

        Task { @MainActor [weak playbackModel = loaded.playbackModel] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            playbackModel?.persistLocation()
        }
    }

    // MARK: - Position resolve before play (PP-4542)

    /// PP-4542: maximum time to wait for the server-synced position before
    /// opening at the local/beginning position, so a slow backend can't stall
    /// audiobook open. Audiobook bookmarks normally return in ~0.5s; this is the
    /// rare-slow-case safety valve.
    static let remotePositionResolveTimeout: TimeInterval = 2.5

    /// Resolves the position to OPEN at: awaits the remote bookmark (bounded) and
    /// prefers it over the local position only when meaningfully newer (the same
    /// >5s rule the prior post-play seek used), otherwise returns `fallback`
    /// (local-or-beginning). Running this BEFORE the first play is what removes
    /// the "jump" — the player opens directly at the resolved spot.
    @MainActor
    private func resolveInitialPosition(
        for book: TPPBook,
        audiobook: Audiobook,
        localPosition: TrackPosition?,
        fallback: TrackPosition
    ) async -> TrackPosition {
        guard let remote = await awaitRemotePosition(
            for: book,
            audiobook: audiobook,
            timeout: Self.remotePositionResolveTimeout
        ) else {
            Log.debug(#file, "No remote position resolved before play — opening at local position")
            return fallback
        }
        guard Self.preferRemotePosition(local: localPosition, remote: remote) else {
            Log.debug(#file, "Local position is current — opening at local position")
            return fallback
        }
        // Manifest-validate the REMOTE position with the SAME gate the local
        // path applies (`tryLoadPrimaryLocalPosition` at the `validationFailure`
        // seam): a stale remote track key absent from the loaded manifest is
        // exactly the 3.2.3 Cause 2 failure — seeking it verbatim opens at a
        // phantom position. Drop to the safe fallback (local-or-Ch1) instead.
        let resolved = validatedRemotePosition(
            remote,
            fallback: fallback,
            in: audiobook.tableOfContents,
            bookId: book.identifier
        )
        return resolved
    }

    /// Applies the manifest-validation gate to a resolved REMOTE position,
    /// mirroring the local path's `validationFailure(for:in:)` check. Returns
    /// `remote` when it validates against the loaded manifest, else `fallback`
    /// — a remote track key that isn't in the manifest must NOT be seeked
    /// verbatim (3.2.3 Cause 2). `internal` so the decision is unit-pinnable
    /// with a real TOC + a foreign-keyed position, the same way the local
    /// `validationFailure` / `selectMostRecentValidBookmark` seams are.
    func validatedRemotePosition(
        _ remote: TrackPosition,
        fallback: TrackPosition,
        in tableOfContents: AudiobookTableOfContents,
        bookId: String
    ) -> TrackPosition {
        if let failure = validationFailure(for: remote, in: tableOfContents) {
            let manifestKeys = tableOfContents.tracks.tracks
                .prefix(5).map(\.key).joined(separator: ",")
            positionLogger.logFailure(
                reason: failureReasonString(failure),
                context: [
                    "bookId": bookId,
                    "savedKey": remote.track.key,
                    "manifestKeys": manifestKeys,
                    "source": "remote"
                ]
            )
            return fallback
        }
        Log.info(#file, "📡 Opening at remote position (newer than local): track=\(remote.track.key), timestamp=\(remote.timestamp)")
        return remote
    }

    /// Bounded await of the server-synced position. Resolves to the remote
    /// `TrackPosition` if the bookmark sync returns one within `timeout`, else
    /// `nil` (slow/again backend or no remote bookmark). Single-resume guarded so
    /// the timeout and the sync callback race safely. No-ops to `nil` for a
    /// mock-injected registry (tests), so the local position alone drives open.
    @MainActor
    private func awaitRemotePosition(
        for book: TPPBook,
        audiobook: Audiobook,
        timeout: TimeInterval
    ) async -> TrackPosition? {
        guard let concreteRegistry = bookRegistry as? TPPBookRegistry else { return nil }
        let toc = audiobook.tableOfContents
        return await withCheckedContinuation { (cont: CheckedContinuation<TrackPosition?, Never>) in
            let once = PositionResolveOnce()
            concreteRegistry.syncLocation(for: book) { (remoteBookmark: AudioBookmark?) in
                let position = remoteBookmark.flatMap {
                    TrackPosition(audioBookmark: $0, toc: toc.toc, tracks: toc.tracks)
                }
                once.fire { cont.resume(returning: position) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                once.fire { cont.resume(returning: nil) }
            }
        }
    }

    /// True iff `remote` should be preferred over `local` — i.e. the remote save
    /// is >5s newer (no local ⇒ prefer remote). Pure/static so it's unit-pinnable.
    static func preferRemotePosition(local: TrackPosition?, remote: TrackPosition) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let remoteDate = formatter.date(from: remote.lastSavedTimeStamp) else { return false }
        guard let local = local,
              let localDate = formatter.date(from: local.lastSavedTimeStamp) else {
            return true
        }
        return remoteDate.timeIntervalSince(localDate) > 5.0
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

    // MARK: - LCP first-open reliable start (WS-5 / F-011)

    /// Dedicated LCP first-open budget. UNLIKE `readinessTimeout` (an
    /// await-budget tuned for already-loaded non-LCP players), this is a
    /// "nudge budget": `LCPStreamingPlayer.isLoaded` only flips AFTER a
    /// successful `play()`, so we cannot await-then-play (it would deadlock —
    /// see the bypass rationale at the call site). Instead we play, then
    /// re-issue every `lcpFirstPlayRetryInterval` until the engine reports
    /// playing or the budget exhausts — the programmatic equivalent of the
    /// nav-away-and-back workaround. Stays well below the toolkit's own 30s
    /// `.failed` timeout so a genuine non-start still surfaces through the
    /// toolkit; we never synthesize a false Palace error.
    ///
    /// PROVISIONAL: 3.0s/0.5s is unvalidated — real LCP first-open engine init
    /// (network + decrypt) must be MEASURED on device/simdrive with a live LCP
    /// title and tuned. Folds into the same Mac/device validation pass as the
    /// WS-4 Adobe `_exit` ceiling (see the WS-5 ADR validation section).
    static let lcpFirstPlayBudget: TimeInterval = 3.0
    static let lcpFirstPlayRetryInterval: TimeInterval = 0.5

    /// LCP first-open reliable start: issue `play(at:)`, then re-issue every
    /// `retryInterval` while the engine has NOT confirmed playing, bounded by
    /// `budget`. The re-issue is SUPPRESSED the instant `probe.isCurrentlyReady()`
    /// is true — `play()` can take effect between the gate wait and the
    /// re-issue decision, and we must never double-start a playing engine
    /// (no seek-to-zero / double-audio glitch). On budget exhaustion we stay
    /// SILENT and defer to the toolkit's own 30s `.failed`; we do NOT surface a
    /// Palace error (that would mask a genuine non-start). Extracted +
    /// spy-seamed so the retry logic is unit- and mutation-testable without a
    /// real Player.
    @MainActor
    internal func confirmLCPFirstPlay(
        bookId: String,
        initialPosition: TrackPositionShape,
        probe: PlaybackReadinessProbing,
        command: PlaybackEngineCommanding,
        budget: TimeInterval,
        retryInterval: TimeInterval
    ) async {
        let gate = PlaybackReadinessGate()
        probe.start(driving: gate)
        defer { probe.stop() }

        // Deterministic bound from the nudge-budget: re-issue at most
        // ceil(budget / retryInterval) times. Count-based (not wall-clock) so
        // the retry behaviour is deterministic and unit-testable.
        let maxAttempts = max(1, Int((budget / retryInterval).rounded(.up)))

        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            await issueLCPPlay(command, at: initialPosition, attempt: attempt, bookId: bookId)
            do {
                let outcome = try await gate.awaitReady(timeout: retryInterval)
                switch outcome {
                case .ready:
                    Log.info(#file, "🎵 LCP first-open engine confirmed playing after \(attempt) attempt(s)")
                    return
                case .failed(let reason):
                    Log.error(#file, "LCP first-open playback failed: \(reason)")
                    return
                }
            } catch PlaybackReadinessError.timeout {
                // Caveat: re-check IMMEDIATELY — a play() that took effect
                // between the gate wait and now must suppress the re-issue so
                // we never double-start a playing engine.
                if probe.isCurrentlyReady() {
                    Log.info(#file, "🎵 LCP first-open engine became ready during gate wait — re-issue suppressed (\(attempt) attempt(s))")
                    return
                }
                // else: the loop re-issues play on the next iteration.
            } catch {
                Log.error(#file, "LCP first-open readiness wait error: \(error)")
                return
            }
        }
        Log.warn(#file, "LCP first-open not confirmed within \(maxAttempts) attempt(s) (~\(budget)s) — deferring to toolkit's own 30s timeout (PP-4436 / F-011)")
    }

    @MainActor
    private func issueLCPPlay(
        _ command: PlaybackEngineCommanding,
        at position: TrackPositionShape,
        attempt: Int,
        bookId: String
    ) async {
        do {
            try await command.play(at: position)
        } catch {
            Log.error(#file, "LCP first-open play(at:) attempt \(attempt) error (\(bookId)): \(error)")
        }
    }

    // MARK: - Chapter TOC normalization

    /// Passthrough. TOC collapse now lives entirely in the toolkit's
    /// `AudiobookTableOfContents` (one chapter per physical track for
    /// oversubdivided / dense manifests), so the app consumes the already-collapsed
    /// list directly. This eliminates the SECOND collapse implementation that
    /// diverged from the toolkit and produced the Findaway "Dune" dual chapter-
    /// numbering (the toolkit used the uncollapsed list for currentChapter /
    /// NowPlaying / saved-position while the app displayed the collapsed one).
    /// Retained as a named seam for the bind site (`currentChapters`) + tests.
    static func normalizedChapters(for toc: AudiobookTableOfContents) -> [Chapter] {
        toc.toc
    }

    /// Test-only spec for the 1.5x oversubdivision THRESHOLD (one chapter per
    /// physical track when `tocCount > trackCount * 1.5`). NOTE: this is no longer
    /// the production collapse seam — `normalizedChapters(for:)` is now a passthrough
    /// and the collapse is implemented in the toolkit's `AudiobookTableOfContents`
    /// (`isOversubdivided` + keep-first). This primitive is retained only to keep the
    /// threshold math pinned by unit tests without constructing toolkit types; it
    /// does not drive any production code path.
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
    // `internal` (not `private`) so `@testable import Palace` unit tests can
    // drive the position-restore decision through this production seam with
    // constructed registry/TOC fixtures — see AudiobookPositionRestoreTests.
    // This is the same seam-exposure pattern already used by the static
    // policy mirrors (networkValidationError, normalizedChaptersCount).
    func getValidLocalPosition(book: TPPBook, audiobook: Audiobook) -> TrackPosition? {
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
    func fallbackToMostRecentValidBookmark(
        book: TPPBook,
        audiobook: Audiobook
    ) -> TrackPosition? {
        let bookmarks = bookRegistry.genericBookmarksForIdentifier(book.identifier)
        guard !bookmarks.isEmpty else { return nil }
        return selectMostRecentValidBookmark(
            from: bookmarks,
            in: audiobook.tableOfContents
        )
    }

    /// Pure candidate-selection seam: from a set of saved generic bookmarks,
    /// reconstruct each against the manifest, drop any that fail validation,
    /// and return the most-recent valid one (descending `lastSavedTimeStamp`,
    /// which is ISO8601 and therefore lexicographically sortable).
    ///
    /// `internal` (not `private`) and threaded `AudiobookTableOfContents`
    /// instead of the full `Audiobook` so the validation filter and the
    /// recency ordering are mutation-testable from a unit test with a real
    /// TOC + seeded `TPPBookLocation` fixtures — no live `Audiobook` /
    /// player graph required. Mirrors the `validationFailure(for:in:)` seam.
    func selectMostRecentValidBookmark(
        from bookmarks: [TPPBookLocation],
        in tableOfContents: AudiobookTableOfContents
    ) -> TrackPosition? {
        let candidates: [(TrackPosition, String)] = bookmarks.compactMap { location in
            guard let dict = location.locationStringDictionary(),
                  let bookmark = AudioBookmark.create(locatorData: dict),
                  let position = TrackPosition(
                    audioBookmark: bookmark,
                    toc: tableOfContents.toc,
                    tracks: tableOfContents.tracks
                  ),
                  validationFailure(for: position, in: tableOfContents) == nil else {
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
    func validationFailure(
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
    func isValidPosition(_ position: TrackPosition, in tableOfContents: AudiobookTableOfContents) -> Bool {
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

#if FEATURE_OVERDRIVE
    /// WS-3 (3.2.0 crash-triage `04373e48`/`d2c9e0ef`): an OverDrive audiobook
    /// streams from time-limited SIGNED URLs embedded in its on-disk manifest.
    /// When those URLs expire the toolkit surfaces a `.playbackFailed` carrying
    /// an HTTP-`410` error and — because OverDrive is not SAML — the recovery in
    /// `handleManagerState` falls through to a `.unknown` dead-end with no way to
    /// play. Returns true when the failure is a RECOVERABLE signed-URL expiry a
    /// fresh re-fulfill can fix: an OverDrive book, an HTTP-410 (Gone) signal, and
    /// no prior re-fulfill this session.
    ///
    /// Conservative by design (per "when in doubt, don't re-fulfill — a false
    /// dead-end is safer than retrying into a revoked loan"): 401/auth and
    /// loan-revoked are handled elsewhere (toolkit bearer refresh / SAML re-auth)
    /// and are NOT retried here; HTTP-403 is excluded because it is ambiguous
    /// (signed-URL expiry vs entitlement denial) absent a confirmed OverDrive
    /// expiry signature; an error with no extractable HTTP status is NOT retried.
    /// Mirrors `shouldTriggerSAMLReauthForPlaybackFailure`.
    static func shouldTriggerOverdriveRefulfillForPlaybackFailure(
        error: Error?,
        book: TPPBook?,
        alreadyAttempted: Bool
    ) -> Bool {
        guard !alreadyAttempted, let book else { return false }
        guard book.distributor?.lowercased() == OverdriveDistributorKey.lowercased() else { return false }
        guard let status = httpStatusCode(from: error) else { return false }
        return status == 410
    }

    /// PP-4542: decides whether a `.playbackFailed` should trigger ONE silent
    /// auto-reopen before surfacing the "Audiobook Unavailable" alert. Pure so
    /// the per-session bound is unit-pinned without driving the auth-gated open
    /// flow. Distributor-agnostic on purpose: the regression (Readium 3.9.0
    /// rangeOutOfBounds on a not-yet-materialized LCP package) is a cold-load
    /// race that any first-open can hit, and a reopen demonstrably recovers it.
    /// - `hasEverStartedPlayback == false`: only a COLD-load failure (playback
    ///   never started this session) is a candidate; a mid-playback failure is a
    ///   different surface and must NOT silently reopen.
    /// - `hasCurrentBook`: there must be a book to reopen.
    /// - `alreadyAttempted == false`: bounded to one reopen per book per session
    ///   so a genuinely persistent failure reaches the alert instead of looping.
    static func shouldAutoReopenOnColdLoadFailure(
        hasEverStartedPlayback: Bool,
        hasCurrentBook: Bool,
        alreadyAttempted: Bool
    ) -> Bool {
        !hasEverStartedPlayback && hasCurrentBook && !alreadyAttempted
    }

    /// Extracts an HTTP status code from a playback error. The toolkit's network
    /// layer stamps `userInfo["httpStatusCode"]` on download/streaming failures
    /// (`OpenAccessDownloadTask`); we also walk one level of the
    /// `NSUnderlyingError` chain.
    static func httpStatusCode(from error: Error?) -> Int? {
        guard let nsError = error as NSError? else { return nil }
        if let status = nsError.userInfo["httpStatusCode"] as? Int { return status }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let status = underlying.userInfo["httpStatusCode"] as? Int {
            return status
        }
        return nil
    }
#endif

    /// True once the LCP audiobook's full content package is on disk. The `.lcpa`
    /// is moved into place atomically on download completion
    /// (BackgroundDownloadHandler.replaceBook), so file existence == content
    /// complete — the same signal `LCPAdapter.prepareLCPSource` uses to prefer
    /// the reliable local path over streaming.
    static func audiobookContentIsLocal(_ bookId: String) -> Bool {
        guard let url = AppContainer.production().downloadCenter.fileUrl(for: bookId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Awaits a freshly-borrowed audiobook's content download landing on disk by
    /// polling existence of the local package. The download is already in flight
    /// (it auto-starts on borrow), so this is a *wait*, not a trigger. Bounded so
    /// a stalled/failed download can't hold the loading state forever; on timeout
    /// the caller surfaces the unavailable alert (i.e. no worse than today, just
    /// after giving the in-flight download a chance to finish).
    static func awaitAudiobookContentLocal(
        _ bookId: String,
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 0.5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if audiobookContentIsLocal(bookId) { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return audiobookContentIsLocal(bookId)
    }

    /// Dismisses the player UI and shows the honest "couldn't play right now"
    /// alert used by the cold-load failure paths. Factored so the immediate
    /// failure path and the PP-4542 await-local-content timeout path present an
    /// identical experience.
    private func dismissAndPresentColdLoadUnavailable() async {
        // Cold-load failure path: the player never started, so there is no
        // meaningful "live position" to persist.
        await self.stopPlayback(dismissPhoneUI: true, persistFinalPosition: false)
        await MainActor.run {
            let alert = TPPAlertUtils.alert(
                title: NSLocalizedString("Audiobook Unavailable", comment: "Title when a cold-load playback failure dismisses the player"),
                message: NSLocalizedString("This audiobook couldn't be played right now. The content may be temporarily unavailable — please try again later or contact your library.", comment: "Message when a cold-load playback failure dismisses the player")
            )
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        }
    }

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
    // `internal` (not `private`) so `@testable` tests can pin the
    // auth-doc-load-failure → not-authenticated mapping (the `catch`
    // branch below) through this seam — see AudiobookPositionRestoreTests.
    func isUserAuthenticated() async -> Bool {
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

    /// Internal (was private) so the WS-3 integration test can drive the
    /// `.playbackFailed` OverDrive re-fulfill recovery directly. Visibility
    /// widening only — no new public API, no behavior change.
    func handleManagerState(_ managerState: AudiobookManagerState) {
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
            // PP-4542 (A): if we're already parked awaiting this book's content
            // download (a fresh-borrow streaming failure), swallow the streaming
            // player's follow-on failure storm. Without this, a second
            // `.playbackFailed` slips past the auto-reopen guard (alreadyAttempted
            // is now true) and dead-ends to the "Unavailable" alert while the
            // await is still in flight — which is exactly what defeated the wait
            // in the field repro.
            if awaitingContentDownloadBookIds.contains(bookId) {
                Log.info(#file, "Ignoring follow-on playback failure for \(bookId) — already awaiting content download (PP-4542)")
                return
            }

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

#if FEATURE_OVERDRIVE
            // WS-3 (3.2.0 crash-triage): OverDrive streams from time-limited
            // signed URLs and has no SAML session to re-auth — an expired URL
            // (HTTP 410) would otherwise dead-end here as `.unknown`. Re-fulfill
            // FRESH signed URLs (bypassing the stale on-disk manifest) and
            // re-open. Bounded to one attempt per session so a persistent
            // failure cannot loop on this shared handler.
            if Self.shouldTriggerOverdriveRefulfillForPlaybackFailure(
                error: error,
                book: currentBook,
                alreadyAttempted: overdriveRefulfillAttemptedBookIds.contains(bookId)
            ), let book = currentBook {
                Log.info(#file, "OverDrive audiobook playback failed on an expired signed URL — re-fulfilling fresh URLs and re-opening")
                overdriveRefulfillAttemptedBookIds.insert(bookId)
                Task { [weak self] in
                    guard let self else { return }
                    guard self.currentBook?.identifier == book.identifier else { return }
                    _ = await self.openAudiobook(book, startPlaying: true, forceRefulfill: true)
                }
                return
            }
#endif

            // PP-4542: cold-load auto-recovery. A first cold open of an LCP
            // audiobook can fail transiently because the encrypted package
            // isn't fully materialized yet — the toolkit's resource loader
            // reads a byte-range past the not-yet-complete ZIP and surfaces
            // ReadiumZIPFoundation rangeOutOfBounds (a Readium 3.9.0 / PP-4340
            // regression). Re-opening succeeds once the data has landed, which
            // is exactly what users discover by re-tapping. Do ONE re-open
            // automatically before surfacing any error. Bounded to one attempt
            // per book per session (mirrors the OverDrive refulfill guard) so a
            // genuinely persistent failure can't loop and still reaches the
            // alert below. The toolkit-side retry (LCPResourceLoaderDelegate) is
            // the primary fix; this is the belt-and-suspenders guard for
            // cold-load failures it doesn't absorb.
            if Self.shouldAutoReopenOnColdLoadFailure(
                   hasEverStartedPlayback: hasEverStartedPlayback,
                   hasCurrentBook: currentBook != nil,
                   alreadyAttempted: coldLoadReopenAttemptedBookIds.contains(bookId)
               ), let book = currentBook {
                coldLoadReopenAttemptedBookIds.insert(bookId)

                // PP-4542 (A): the freshly-borrowed LCP audiobook case. A book is
                // marked download-successful the instant the tiny .lcpl license
                // lands, but the full .lcpa content keeps downloading in the
                // background and only lands atomically on completion. Until then,
                // the open *streams* — and streaming a fresh borrow is unreliable
                // (the 3.2.0-only "Audiobook Unavailable"; root cause tracked as
                // B). Re-opening the SAME not-ready stream a few ms later just
                // fails again, even though simply waiting for the in-flight
                // download would play perfectly from the local path (exactly what
                // users discover by re-tapping later). So when the content isn't
                // on disk yet, hold a loading state and re-open from the reliable
                // local path the moment the download lands — instead of dead-
                // ending to the alert.
                // Cannot stack with the upfront `#if LCP` gate in openAudiobook:
                // that gate fires BEFORE any playback attempt and `return`s on
                // timeout (no loader.load → no streaming → no .playbackFailed),
                // and on success the content is local so the guard below is
                // false. This reactive wait therefore only covers non-LCP books
                // downloading mid-open — a single 180s window, never 180+180.
                if !Self.audiobookContentIsLocal(book.identifier) {
                    Log.info(#file, "Cold-load failure while content still downloading — awaiting local content before re-opening (PP-4542)")
                    // Park this book so the streaming player's follow-on failure
                    // storm is swallowed (see the guard at the top of this case)
                    // instead of racing past us to the "Unavailable" alert.
                    awaitingContentDownloadBookIds.insert(book.identifier)
                    state = .loading(bookId: book.identifier)
                    playbackStatePublisher.send(state)
                    Task { [weak self] in
                        guard let self else { return }
                        let becameLocal = await Self.awaitAudiobookContentLocal(book.identifier)
                        // The wait is over — stop swallowing failures for this book
                        // so the re-open's own success/failure drives the UI.
                        self.awaitingContentDownloadBookIds.remove(book.identifier)
                        guard self.currentBook?.identifier == book.identifier else { return }
                        if becameLocal {
                            Log.info(#file, "Content download landed — re-opening audiobook from local path")
                            _ = await self.openAudiobook(book, startPlaying: true, forceRefulfill: false, isColdLoadRecovery: true)
                        } else {
                            Log.info(#file, "Content download did not land within wait window — surfacing unavailable alert")
                            await self.dismissAndPresentColdLoadUnavailable()
                        }
                    }
                    return
                }

                Log.info(#file, "Cold-load failure detected — attempting one automatic re-open before surfacing alert")
                Task { [weak self] in
                    guard let self else { return }
                    guard self.currentBook?.identifier == book.identifier else { return }
                    _ = await self.openAudiobook(book, startPlaying: true, forceRefulfill: false, isColdLoadRecovery: true)
                }
                return
            }

            errorPublisher.send(.unknown("Playback failed"))

            // Cold-load failure that persisted past the one silent auto-reopen
            // above (or a failure after playback had already started): dismiss
            // the player and surface an honest "not playable right now" alert.
            // NOT a retry offer — we already retried once silently; a button
            // would just invite rage-tapping for no outcome. The user can re-tap
            // the book themselves; that's natural UX, not a fake affordance.
            if !hasEverStartedPlayback, currentBook != nil {
                Log.info(#file, "Cold-load failure persisted after auto re-open — dismissing player UI and showing unavailable alert")
                Task { [weak self] in
                    guard let self else { return }
                    await self.dismissAndPresentColdLoadUnavailable()
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

/// One-shot resume guard (PP-4542): ensures a `CheckedContinuation` is resumed
/// exactly once when a bounded await races a timeout against a completion
/// callback. NSLock-guarded so the (possibly background-thread) sync callback and
/// the MainActor timeout can race safely without a double-resume trap.
private final class PositionResolveOnce {
    private let lock = NSLock()
    private var fired = false
    func fire(_ block: () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        block()
    }
}
