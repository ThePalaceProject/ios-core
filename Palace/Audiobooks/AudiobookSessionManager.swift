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
import PalacePreferences
import Foundation
import MediaPlayer
import os
import PalaceAudiobookToolkit
import PalaceCatalog
import PalaceLogging
import PalaceNetwork
import PalaceBookModel
import PalaceBookRegistry
import PalaceUtilities

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

// MARK: - ContentGateResult

/// Outcome of the pre-open LCP content gate (PP-4542). Returned
/// by `gateOnLCPContentDownload` so `openAudiobook` can act on it without the
/// gate itself touching UI or instance identity state.
///
/// - `proceed`: nothing was awaited — the content is already on disk, or the
///   gate wasn't applicable (not an LCP book, or a cold-load recovery re-open).
///   Open immediately.
/// - `landedAfterTrigger`: the content download was TRIGGERED and the `.lcpa`
///   landed within the wait window. Open from the local package (after the
///   caller re-checks open identity, since an `await` elapsed).
/// - `contentUnavailable`: the download was triggered but the content did not
///   land within the wait window. Caller surfaces the existing "Audiobook
///   Unavailable" experience.
enum ContentGateResult: Equatable {
    case proceed
    case landedAfterTrigger
    case contentUnavailable
}

// MARK: - AudiobookSessionManager

/// Singleton manager that owns audiobook playback state.
/// Thread-safe via MainActor isolation.
///
/// Account switch: `cleanupActiveContentBeforeAccountSwitch(...)` cancels
/// in-flight playtimes POSTs. The `AudiobookDataManager` queue is process-wide
/// and its `syncValues()` skips entries for non-current libraries, so the
/// session manager takes no further action.
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

    /// PP-5205. `currentChapter` is a cache whose only writer used to be
    /// `handlePositionUpdate` — so a chapter tap changed nothing until the seek
    /// produced a position, and a seek pauses the player, which is the absence of
    /// exactly that stream. The mechanism lives in the collaborator; the decisions
    /// live in `ChapterNavigationPolicy`.
    private let chapterNavigationHold = ChapterNavigationHold()

    private(set) var audiobook: Audiobook?
    private(set) var manager: AudiobookManager? {
        didSet {
            // Compute the Bool on the (main) actor BEFORE entering the
            // `@Sendable` `withLock` closure. Referencing the `@MainActor`
            // `manager` property from INSIDE that closure does not compile under
            // Swift 6 ("main actor-isolated property 'manager' can not be
            // referenced from a Sendable closure") — this broke the develop build
            // after #1222 merged. The Bool snapshot is Sendable, so hoisting it
            // out fixes it with identical behavior.
            let isActive = (manager != nil)
            Self._hasActiveManagerMirror.withLock { $0 = isActive }
        }
    }
    private(set) var playbackModel: AudiobookPlaybackModel?
    private(set) var nowPlayingCoordinator: NowPlayingCoordinator?

    /// Surface for the `AudiobookSessionManaging` protocol — exposes whether
    /// an `AudiobookManager` is bound without leaking the toolkit type
    /// through the protocol.
    public var hasActiveManager: Bool { manager != nil }

    /// Off-main-safe mirror of `hasActiveManager` (`manager != nil`).
    ///
    /// Remote-command handlers run on a background MediaRemote queue, where
    /// reading the `@MainActor` `hasActiveManager` trips
    /// `dispatch_assert_queue_fail` (#1199, #1218). This lock-guarded snapshot
    /// is written on main by `manager`'s `didSet` and readable from any thread.
    /// Static because there is a single manager per process.
    // `nonisolated` so the `nonisolated` `hasActiveManagerSnapshot` can read
    // it; `OSAllocatedUnfairLock` is `Sendable`.
    nonisolated private static let _hasActiveManagerMirror =
        OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Off-main-safe read of "is a manager currently bound." Reflects the last
    /// main-actor `bind`/`stopPlayback` transition; the write window is a single
    /// main-actor hop, so any staleness is sub-frame and self-correcting.
    nonisolated static var hasActiveManagerSnapshot: Bool {
        _hasActiveManagerMirror.withLock { $0 }
    }

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

    let bookRegistry: TPPBookRegistryProvider

    /// Owns the open-time position decision (local vs server-synced vs
    /// beginning) and the `[AUDIOPOS]` diagnostics that go with it.
    /// `internal` so `@testable` tests drive the seams directly, the same way
    /// they drove them when this code was inline here.
    let positionResolver: AudiobookPositionResolver

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
    /// during cold launch / CarPlay background launch. Used only by the
    /// in-app-nav-off path (pushed `.audio` route).
    private let navigationCoordinatorHubProvider: () -> NavigationCoordinatorHub

    /// Resolves the root-level audiobook session presenter. Production uses
    /// the cached `AppContainer.production().audiobookSessionPresenter`; tests
    /// pass a spy. `@MainActor` because that accessor is.
    private let audiobookSessionPresenterProvider: @MainActor () -> AudiobookSessionPresenter

    /// Resolves whether the in-app-playback-nav feature is enabled. Gates
    /// which presentation `presentSession` drives: off → the legacy
    /// full-screen pushed `.audio` route; on → the root-level presenter
    /// (mini-player + full-player overlay). Production default reads
    /// `RemoteFeatureFlags.shared`; tests inject a fixed value so the
    /// flag-branch decision is exercised without touching UserDefaults.
    private let inAppPlaybackNavEnabledProvider: () -> Bool

    /// PP-4542: triggers the LCP `.lcpa` content download for an audiobook whose
    /// `.lcpl` license is on disk but whose content is not (typically lost or
    /// interrupted). Polling alone could wait on a download that is not running.
    /// Production wires `downloadCenter.redownloadLCPContentFile`, the same
    /// idempotent self-heal `BookRegistrySync` uses.
    private let lcpContentDownloadTrigger: (TPPBook) -> Void

    /// PP-4957: reads the LCP-audiobook-streaming feature flag. When ON, an LCP
    /// audiobook is playable on its license alone, so the open-time content gate
    /// (`gateOnLCPContentDownload`) must NOT force a download before opening —
    /// the player streams via the swift-toolkit #579 fork. Injected so tests
    /// drive both flag states; production default reads `RemoteFeatureFlags.shared`
    /// (local override > Firebase remote, default `false` → download-first).
    private let lcpStreamingEnabledProvider: () -> Bool

    // MARK: - Readiness-gate injection points
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
    /// coordinator to finish initializing on the first open. 2.0s is well
    /// above typical Findaway / OpenAccess init (~80ms) while still surfacing
    /// a stuck coordinator. LCP audiobooks bypass the gate (see
    /// `startPlaybackAndSyncPosition`).
    private let readinessTimeout: TimeInterval

    /// PP-5241: recovers the session after iOS resets its media services
    /// (AVError -11819 / `mediaServicesWereResetNotification`). Observes the
    /// injected `NotificationCenter`; this manager is its host. See
    /// `MediaServicesResetRecovery.swift`.
    private let mediaServicesResetRecovery: MediaServicesResetRecovery

    /// Starts OverDrive fulfilment for a book through the download centre
    /// (PP-4800). Injected so the recovery's bookkeeping is testable without
    /// the production download centre.
    let overdriveRefulfillStarter: @MainActor (TPPBook) -> Void

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
        lcpContentDownloadTrigger: @escaping (TPPBook) -> Void,
        lcpStreamingEnabledProvider: @escaping () -> Bool,
        readinessProbeFactory: @escaping @MainActor (Player) -> PlaybackReadinessProbing,
        playbackCommandFactory: @escaping @MainActor (Player) -> PlaybackEngineCommanding,
        readinessTimeout: TimeInterval,
        notificationCenter: NotificationCenter,
        overdriveRefulfillStarter: @escaping @MainActor (TPPBook) -> Void,
        makeLoader: @escaping @MainActor (Bool) -> AudiobookLoader
    ) {
        self.bookRegistry = bookRegistry
        self.positionResolver = AudiobookPositionResolver(bookRegistry: bookRegistry)
        self.accountsManager = accountsManager
        self.settings = settings
        self.reachabilityProvider = reachabilityProvider
        self.bookCoverRegistryProvider = bookCoverRegistryProvider
        self.navigationCoordinatorHubProvider = navigationCoordinatorHubProvider
        self.audiobookSessionPresenterProvider = audiobookSessionPresenterProvider
        self.inAppPlaybackNavEnabledProvider = inAppPlaybackNavEnabledProvider
        self.lcpContentDownloadTrigger = lcpContentDownloadTrigger
        self.lcpStreamingEnabledProvider = lcpStreamingEnabledProvider
        self.readinessProbeFactory = readinessProbeFactory
        self.playbackCommandFactory = playbackCommandFactory
        self.readinessTimeout = readinessTimeout
        self.mediaServicesResetRecovery = MediaServicesResetRecovery(notificationCenter: notificationCenter)
        self.overdriveRefulfillStarter = overdriveRefulfillStarter
        self.makeLoader = makeLoader
        Log.info(#file, "AudiobookSessionManager initialized")
        nowPlayingCoordinator = NowPlayingCoordinator()
        // Note: Remote commands are handled by the toolkit's MediaControlPublisher.
        // This manager now owns the full audiobook lifecycle (load → bind → play)
        // directly via AudiobookLoader; no pub/sub handoff is needed.
        subscribeToPhoneSideErrorAlerts()
        subscribeToBookReturn()
        subscribeToAppLifecyclePositionPersistence()
        mediaServicesResetRecovery.host = self
    }

    /// AppContainer-friendly initializer. Used by future call sites that
    /// thread the container down to here. Provider closures default to
    /// `.shared` accessors since AppContainer doesn't currently hold
    /// Reachability / TPPBookCoverRegistry / NavigationCoordinatorHub.
    ///
    /// `readinessProbeFactory` / `playbackCommandFactory` / `readinessTimeout`
    /// default to production wiring (poll `Player.isLoaded`, forward to
    /// `Player.play(at:)`, 2.0s budget).
    convenience init(
        appContainer: AppContainer,
        reachabilityProvider: @escaping () -> Reachability = { AppContainer.production().reachability },
        bookCoverRegistryProvider: @escaping () -> TPPBookCoverRegistry = { TPPBookCoverRegistry.shared },
        navigationCoordinatorHubProvider: @escaping () -> NavigationCoordinatorHub = { AppContainer.production().navigationCoordinatorHub },
        audiobookSessionPresenterProvider: @escaping @MainActor () -> AudiobookSessionPresenter = { AppContainer.production().audiobookSessionPresenter },
        inAppPlaybackNavEnabledProvider: @escaping () -> Bool = { RemoteFeatureFlags.shared.isInAppPlaybackNavEnabled },
        lcpContentDownloadTrigger: @escaping (TPPBook) -> Void = { book in
            AppContainer.production().downloadCenter.redownloadLCPContentFile(for: book)
        },
        lcpStreamingEnabledProvider: @escaping () -> Bool = { RemoteFeatureFlags.shared.isLCPAudiobookStreamingEnabled },
        readinessProbeFactory: @escaping @MainActor (Player) -> PlaybackReadinessProbing = { player in
            PlayerReadinessProbe(isLoadedSnapshot: { [weak player] in player?.isLoaded ?? false })
        },
        playbackCommandFactory: @escaping @MainActor (Player) -> PlaybackEngineCommanding = { player in
            ToolkitPlayerCommand(player: player)
        },
        readinessTimeout: TimeInterval = 2.0,
        notificationCenter: NotificationCenter = .default,
        overdriveRefulfillStarter: @escaping @MainActor (TPPBook) -> Void = { book in
            AppContainer.production().downloadCenter.startDownload(for: book, withRequest: nil)
        },
        makeLoader: @escaping @MainActor (Bool) -> AudiobookLoader = { AudiobookLoader(forceRefulfill: $0) }
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
            lcpContentDownloadTrigger: lcpContentDownloadTrigger,
            lcpStreamingEnabledProvider: lcpStreamingEnabledProvider,
            readinessProbeFactory: readinessProbeFactory,
            playbackCommandFactory: playbackCommandFactory,
            readinessTimeout: readinessTimeout,
            notificationCenter: notificationCenter,
            overdriveRefulfillStarter: overdriveRefulfillStarter,
            makeLoader: makeLoader
        )
    }

    /// Presents phone alerts for validation errors published to
    /// `errorPublisher` (WiFi-only+cellular, not-authenticated,
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

    /// PP-4632: tear the player down when the CURRENTLY-PLAYING book is returned
    /// (or otherwise removed → `.unregistered`). The return flow
    /// (`BookReturnService`) deletes local content + purges caches but cannot
    /// reach this in-memory session; without this, a returned audiobook keeps
    /// playing from the already-loaded tracks (open file handles survive the
    /// file deletion) until a new book is opened. Account-switch teardown is
    /// handled separately (`cleanupActiveContentBeforeAccountSwitch` nils
    /// `currentBook` first), so its mass `.unregistered` emissions no-op here.
    private func subscribeToBookReturn() {
        bookRegistry.bookStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] identifier, state in
                self?.handleRegistryStateChange(identifier: identifier, state: state)
            }
            .store(in: &lifecycleCancellables)
    }

    /// Best-effort position persistence on app background / termination.
    ///
    /// On background and on terminate,
    /// force-save the live position via `playbackModel.persistLocation()`
    /// (which bypasses the throttled autosave suppression window). No-op when
    /// no session is bound. Registered once for the manager's lifetime; the
    /// subscriptions live in `lifecycleCancellables`, so they are torn down
    /// automatically when the manager deallocates (there is no separate deinit
    /// to maintain).
    private func subscribeToAppLifecyclePositionPersistence() {
        let lifecycleNotifications = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ]
        for name in lifecycleNotifications {
            NotificationCenter.default
                .publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.persistActivePositionForLifecycleEvent()
                }
                .store(in: &lifecycleCancellables)
        }
    }

    /// Force-persists the current playback position IF a session is active.
    /// Called from the background / terminate observers wired in
    /// `subscribeToAppLifecyclePositionPersistence`. Best-effort and
    /// non-destructive: when no session is bound it is a pure no-op, so a
    /// background/terminate during a cold launch (nothing playing) never
    /// writes a stale position.
    func persistActivePositionForLifecycleEvent() {
        guard Self.shouldPersistLifecyclePosition(
            hasManager: manager != nil,
            hasBook: currentBook != nil,
            hasModel: playbackModel != nil
        ) else { return }
        // `persistLocation()` force-saves the model's current location,
        // bypassing the autosave suppression window — identical to the path
        // the deleted toolkit keeper invoked on background/terminate.
        playbackModel?.persistLocation()
    }

    /// Pure guard for `persistActivePositionForLifecycleEvent`: only persist
    /// when there is a fully-bound active session (manager + book + model).
    /// `nonisolated static` so the decision is unit-testable without a live
    /// toolkit session (mirrors `shouldStopPlaybackOnRegistryChange` /
    /// `networkValidationError`).
    nonisolated static func shouldPersistLifecyclePosition(
        hasManager: Bool,
        hasBook: Bool,
        hasModel: Bool
    ) -> Bool {
        hasManager && hasBook && hasModel
    }

    private func handleRegistryStateChange(identifier: String, state: TPPBookState) {
        guard Self.shouldStopPlaybackOnRegistryChange(
            state: state,
            changedIdentifier: identifier,
            currentBookIdentifier: currentBook?.identifier
        ) else { return }
        Log.info(#file, "📕 Active book \(identifier) was returned/removed from the registry — stopping playback")
        // persistFinalPosition: false — the book is gone; do not write a stale
        // live position back into a (possibly re-borrowed) registry record.
        Task { await stopPlayback(dismissPhoneUI: true, persistFinalPosition: false) }
    }

    /// Pure decision for `subscribeToBookReturn`: stop only when the book that
    /// changed is the one currently playing AND it has become `.unregistered`
    /// (returned / removed / expired). `nonisolated static` so it is unit-
    /// testable without a live session (mirrors `networkValidationError`).
    nonisolated static func shouldStopPlaybackOnRegistryChange(
        state: TPPBookState,
        changedIdentifier: String,
        currentBookIdentifier: String?
    ) -> Bool {
        state == .unregistered
            && currentBookIdentifier != nil
            && currentBookIdentifier == changedIdentifier
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
        await openAudiobook(book, startPlaying: startPlaying, forceRefulfill: false)
    }

    /// Protocol witness for the early-present variant — threads the
    /// `onLoadingShellPresented` hook into the internal overload so a presenting
    /// caller can dismiss its transient UI (BookDetail half-sheet) the moment the
    /// loading shell appears, not after the whole download lands. See
    /// fix/audiobook-first-open-hang.
    public func openAudiobook(_ book: TPPBook, startPlaying: Bool, onLoadingShellPresented: (@MainActor () -> Void)?) async -> Result<Void, AudiobookSessionError> {
        await openAudiobook(book, startPlaying: startPlaying, forceRefulfill: false, onLoadingShellPresented: onLoadingShellPresented)
    }

    /// Presents the morphing player's loading shell and fires the early
    /// `onLoadingShellPresented` hook — but ONLY for a user-initiated open
    /// (`startPlaying`) with in-app nav on (the two conditions under which a
    /// shell is actually shown). Returns whether the shell was presented.
    ///
    /// Called once from `openAudiobook` immediately after the auth/registry/
    /// network validation passes and before the PP-4542 content-download wait, so
    /// a presenting caller (BookDetail half-sheet) can dismiss its UI as soon as
    /// the player is on screen.
    @discardableResult
    func presentLoadingShellIfEligible(
        for book: TPPBook,
        startPlaying: Bool,
        onLoadingShellPresented: (@MainActor () -> Void)?
    ) -> Bool {
        guard startPlaying, inAppPlaybackNavEnabledProvider() else { return false }
        audiobookSessionPresenterProvider().presentLoadingShell(
            for: book,
            coverImage: book.coverImage ?? book.thumbnailImage
        )
        onLoadingShellPresented?()
        return true
    }

    /// Per-book bounds on the OverDrive re-fulfilment (PP-4800), the
    /// bearer-token re-fulfilment (HelpSpot #18471) and the cold-load re-open
    /// (PP-4542). Each runs at most once per patron-initiated open, so a
    /// persistent failure reaches the patron-facing error instead of looping.
    /// Only a patron open re-arms them; see `AudiobookRecoveryAttempts`.
    private(set) var recoveryAttempts = AudiobookRecoveryAttempts()

    /// Re-arms the recovery bounds when `isPatronOpen`, and returns whether it
    /// did. Every open reports here, so the re-arm rule has one call site.
    func noteOpenForRecoveryBounds(of bookId: String, forceRefulfill: Bool, isColdLoadRecovery: Bool, isRecoveryReopen: Bool) -> Bool {
        let isPatronOpen = AudiobookRecoveryAttempts.isPatronOpen(
            forceRefulfill: forceRefulfill,
            isColdLoadRecovery: isColdLoadRecovery,
            isRecoveryReopen: isRecoveryReopen
        )
        if isPatronOpen {
            recoveryAttempts.notePatronOpen(of: bookId)
        }
        return isPatronOpen
    }

    /// The decision for one `.playbackFailed`, read from the live bounds.
    func playbackFailureOutcome(for book: TPPBook?, bookId: String, error: Error?) -> AudiobookPlaybackOutcome {
        AudiobookPlaybackRecoveryReducer.decide(
            AudiobookPlaybackFailureContext(
                error: error,
                book: book,
                userAccount: accountsManager.currentUserAccount,
                isAwaitingContentDownload: awaitingContentDownloadBookIds.contains(bookId),
                isOverdriveRefulfillInFlight: recoveryAttempts.overdriveRefulfill(for: bookId) == .inFlight,
                overdriveRefulfillAlreadyAttempted: recoveryAttempts.overdriveRefulfill(for: bookId) != .available,
                bearerTokenRefulfillAlreadyAttempted: recoveryAttempts.hasAttemptedBearerTokenRefulfill(for: bookId),
                coldLoadReopenAlreadyAttempted: recoveryAttempts.hasAttemptedColdLoadReopen(for: bookId),
                hasEverStartedPlayback: hasEverStartedPlayback,
                contentIsLocal: {
                    AudiobookSessionManager.audiobookContentIsLocal(bookId)
                }
            )
        )
    }

    /// Spends the bound of a recovery the `.playbackFailed` arm is starting.
    func noteRecoveryStarted(_ recovery: AudiobookPlaybackRecovery, for bookId: String) {
        recoveryAttempts.recordStarted(recovery, for: bookId)
    }

    /// Takes a finished OverDrive re-fulfilment out of flight.
    func noteOverdriveRefulfillFinished(for bookId: String) {
        recoveryAttempts.finishOverdriveRefulfill(for: bookId)
    }

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

    /// PP-5242: the content source of the bound audiobook, captured at bind for
    /// the playback-failure record, and the repeat filter for that record.
    private var boundContentSource: (bookId: String, source: AudiobookContentSource)?
    private var playbackFailureDeduplicator = PlaybackFailureRecordDeduplicator()

    /// Builds the loader for each open; the argument is `forceRefulfill`.
    /// Injected at init so tests can hold a load in flight.
    private(set) var makeLoader: @MainActor (Bool) -> AudiobookLoader

    /// - parameter forceRefulfill: recovery re-open — when true the loader
    ///   bypasses `LocalFileAdapter` so the book re-fulfills FRESH signed URLs
    ///   instead of replaying the expired on-disk manifest. Internal (not part of
    ///   the public `AudiobookSessionManaging` surface); the public 2-param
    ///   witness above delegates here, and the in-class recovery branch calls it.
    func openAudiobook(_ book: TPPBook, startPlaying: Bool, forceRefulfill: Bool, isColdLoadRecovery: Bool = false, isRecoveryReopen: Bool = false, onLoadingShellPresented: (@MainActor () -> Void)? = nil) async -> Result<Void, AudiobookSessionError> {
        Log.info(#file, "Opening audiobook: '\(book.title)' (id: \(book.identifier))\(forceRefulfill ? " [re-fulfill]" : "")\(isColdLoadRecovery ? " [cold-load recovery]" : "")")
        // Record open time so Continue Reading sorts correctly before the
        // first position save lands.
        AppContainer.production().bookOpenTracker.recordOpened(book.identifier)

        // A recovery re-open (PP-4800) re-opens a book the `.playbackFailed`
        // handler parked at `.loading`, so it must bypass this duplicate-open
        // guard; `loadGeneration` still supersedes any concurrent load.
        if case .loading(let loadingId) = state, loadingId == book.identifier, !isRecoveryReopen {
            Log.warn(#file, "Audiobook already loading: \(book.identifier)")
            return .failure(.alreadyLoading)
        }

        // PP-5241: a fresh patron-initiated open ends any media-services-reset
        // episode. Automatic re-opens (including the reset recovery's own,
        // which passes `isRecoveryReopen`) must not, or the episode bound
        // never holds. Below the `.alreadyLoading` guard: a re-tap refused
        // while the recovery holds `.loading` opens nothing, so it must not
        // end the episode.
        //
        // The same rule re-arms the recovery bounds (PP-4967). The OverDrive
        // re-fulfilment re-opens with `isRecoveryReopen`; when that re-open
        // re-armed the bound, a fresh link that also failed started another
        // re-fulfilment, without end.
        if noteOpenForRecoveryBounds(
            of: book.identifier,
            forceRefulfill: forceRefulfill,
            isColdLoadRecovery: isColdLoadRecovery,
            isRecoveryReopen: isRecoveryReopen
        ) {
            mediaServicesResetRecovery.handleSessionEnded()
        }

        let isSameBook = currentBook?.identifier == book.identifier

        if state.isActive {
            // Skip the teardown's final-position save when re-opening the same
            // book; the prior loan's live position would otherwise leak into the
            // freshly-borrowed registry record (HelpSpot 17988).
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

        // Present the player shell before the loader runs, then fire the early
        // hook so the caller can dismiss its own UI underneath it (present-first
        // per the PP-4633 iPad ordering).
        presentLoadingShellIfEligible(
            for: book,
            startPlaying: startPlaying,
            onLoadingShellPresented: onLoadingShellPresented
        )

#if LCP
        // PP-4542: with streaming off, an LCP audiobook whose `.lcpa` is not on
        // disk is not opened by streaming (Readium 3.9.0 streaming-from-license
        // fails with -11849). `gateOnLCPContentDownload` triggers the download
        // and holds the loading state until it lands; cold-load re-opens skip
        // it. Identity is re-checked after the await. Progress feeds the shell
        // only when it is on screen, since the toolkit model that normally
        // drives the bar does not exist until bind.
        let feedProgressToShell = startPlaying && inAppPlaybackNavEnabledProvider()
        var progressSink: (@MainActor @Sendable (Float) -> Void)?
        if feedProgressToShell {
            progressSink = { [weak self] fraction in
                guard let self else { return }
                self.audiobookSessionPresenterProvider().showDownloadProgress(fraction)
            }
        }
        let gateResult = await gateOnLCPContentDownload(
            for: book,
            isColdLoadRecovery: isColdLoadRecovery,
            canOpenLCPBook: LCPAudiobooks.canOpenBook(book),
            contentIsLocal: Self.audiobookContentIsLocal(book.identifier),
            awaitContentLanding: { bookId in
                await Self.awaitAudiobookContentLocal(bookId, onProgress: progressSink)
            }
        )
        if gateResult != .proceed {
            // An await elapsed (download triggered): a newer open (user tapped a
            // different book) may have replaced currentBook + the .loading
            // state; bail if so.
            guard currentBook?.identifier == book.identifier,
                  case .loading(let lid) = state, lid == book.identifier else {
                Log.info(#file, "PP-4542 gate: a newer open superseded \(book.identifier) while awaiting content — bailing")
                return .failure(.alreadyLoading)
            }
            if gateResult == .contentUnavailable {
                Log.info(#file, "PP-4542 gate: content did not finish downloading within the wait window after trigger — surfacing unavailable")
                await dismissAndPresentColdLoadUnavailable()
                return .failure(.unknown("Audiobook content is still downloading"))
            }
            Log.info(#file, "PP-4542 gate: content landed after trigger — opening '\(book.title)' from local package")
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
                        } else if AudiobookPlaybackRecoveryReducer.shouldTriggerSAMLReauthForLoadFailure(
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
                            // PP-5242: carry the load error's cause into the open-failure report.
                            let failureMetadata = Self.openFailureMetadata(
                                loadError: loadError, contentSource: Self.contentSourceForOpen(book: book))
                            BookService.showAudiobookTryAgainError(book: book, failureMetadata: failureMetadata, onFinish: nil)
                        }
                        continuation.resume(returning: .failure(sessionError))
                    }
                }
            }
        }
    }

    /// Plays the current audiobook
    public func play() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot play - no active manager")
            return
        }

        manager.play()
        // Set the authoritative stored `isPlaying` SYNCHRONOUSLY on the user's
        // intent — the toolkit's own `.playbackBegan` echo (which also sets this)
        // lags by a buffer/decode. Without this, `isPlaying` stayed false until
        // that echo, and any reader of it in the gap (the presenter's
        // `$currentLocation` self-heal) would flip the transport glyph back to
        // "play" for a frame — the pause⇄play flicker on first tap.
        isPlaying = true
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
        // Mirror of `play()`: set the authoritative `isPlaying` synchronously on
        // the user's intent so no observer sees a stale `true` before the
        // toolkit's `.playbackStopped` echo arrives.
        isPlaying = false
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

    /// Updates the manager's published `state` and fires
    /// `playbackStatePublisher` so the presenter's `isPlaying` mirror and the
    /// CarPlay bridge see user-initiated play/pause.
    private func publishPlaybackStateChange(isPlaying: Bool) {
        guard let bookId = currentBook?.identifier else { return }
        let newState: AudiobookSessionState = isPlaying
            ? .playing(bookId: bookId)
            : .paused(bookId: bookId)
        state = newState
        playbackStatePublisher.send(newState)
    }

    /// Background-freeze recovery. Called from
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
        // Re-prime the audio session; `ensureInitialized` is idempotent.
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

        // PP-5205: publish the chosen chapter NOW rather than waiting for the seek
        // to produce a position. `ChapterChangeDetector` is deliberately NOT
        // consulted here — it suppresses same-track/different-title pairs so an
        // anthology does not emit a crossing mid-track, which is right for a
        // REACTIVE update and wrong for this one: the patron tapped a different
        // row and the label must say so.
        if let selected = chapterNavigationHold.beginSelection(of: chapter, replacing: currentChapter) {
            currentChapter = selected
            chapterUpdatePublisher.send((chapters: currentChapters, current: currentChapter))
        }

        // Route through the toolkit's sync wrapper (playAtPosition) so the
        // non-Sendable Player / TrackPosition never cross an isolation boundary
        // under the app's strict-concurrency (archive) build. Fire-and-forget.
        (manager as? DefaultAudiobookManager)?.playAtPosition(chapter.position)

        Log.debug(#file, "Skipping to chapter: '\(chapter.title)'")
    }

    /// Skips the playhead backward by the patron's configured back interval
    /// (PP-4712).
    /// The async result is discarded; the toolkit publishes the new position
    /// through `positionPublisher`.
    public func skipBack() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot skipBack — no active manager")
            return
        }
        // PP-4712: honor the patron's configured back interval (not a fixed 30).
        let interval = AudiobookSkipIntervalSettings().backTimeInterval
        (manager as? DefaultAudiobookManager)?.skipPlayhead(-interval)
        Log.debug(#file, "Skipping back \(interval)s")
    }

    /// Skips the playhead forward by the patron's configured forward interval
    /// (PP-4712). See
    /// `skipBack()` for the async-boundary rationale.
    public func skipForward() {
        guard let manager = manager else {
            Log.warn(#file, "Cannot skipForward — no active manager")
            return
        }
        // PP-4712: honor the patron's configured forward interval (not a fixed 30).
        let interval = AudiobookSkipIntervalSettings().forwardTimeInterval
        (manager as? DefaultAudiobookManager)?.skipPlayhead(interval)
        Log.debug(#file, "Skipping forward \(interval)s")
    }

    /// Seeks to a fractional position (0…1) within the CURRENT CHAPTER via the
    /// toolkit's public `DefaultAudiobookManager.seekWithSlider` (which maps the
    /// fraction to `offsetWithinChapter = value * chapterDuration`) — NOT a
    /// fraction of the whole audiobook. Drives the full player's chapter-scoped
    /// scrubber drag. Clamped to [0, 1]; no-ops if no active manager.
    public func seek(to fraction: Double) {
        guard let modernManager = manager as? DefaultAudiobookManager else {
            Log.warn(#file, "Cannot seek — no DefaultAudiobookManager")
            return
        }
        modernManager.seekWithSlider(value: min(max(fraction, 0), 1)) { _ in }
    }

    /// Sets (or clears) the sleep timer via the toolkit's public
    /// `DefaultAudiobookManager.sleepTimer`. Drives the full player's sleep-timer
    /// menu. No-ops if no active manager.
    public func setSleepTimer(_ trigger: SleepTimerTriggerAt) {
        guard let modernManager = manager as? DefaultAudiobookManager else {
            Log.warn(#file, "Cannot set sleep timer — no DefaultAudiobookManager")
            return
        }
        modernManager.sleepTimer.setTimerTo(trigger: trigger)
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

    /// Current playback rate (read) — reflects the toolkit `player.playbackRate`,
    /// fixing the hard-coded "1.0×" label the morphing player showed when a
    /// session was restored at a persisted non-1.0 rate.
    public var currentPlaybackRate: PlaybackRate {
        manager?.audiobook.player.playbackRate ?? .normalTime
    }

    /// Sets an explicit playback rate (for the speed slider). Mirrors
    /// `cyclePlaybackRate`'s now-playing update so the lock screen stays in sync.
    public func setPlaybackRate(_ rate: PlaybackRate) {
        guard let player = manager?.audiobook.player else { return }
        player.playbackRate = rate
        nowPlayingCoordinator?.updatePlaybackRate(rate)
        Log.debug(#file, "Playback rate set to: \(PlaybackRate.convert(rate: rate))x")
    }

    /// True once the toolkit player has buffered/loaded — gates the loading
    /// overlay. Not `@Published`; the view re-reads it on `isPlaying`/position
    /// ticks. (`UnifiedPositionSystem.isLoaded` is `@Published` upstream, so a
    /// crisp presenter mirror is a follow-up if the tick cadence proves too coarse.)
    public var isLoaded: Bool {
        manager?.audiobook.player.isLoaded ?? false
    }

    /// Whether a sleep timer is currently counting down (drives the active-chip
    /// display). Reads the toolkit's public `SleepTimer`.
    public var sleepTimerIsActive: Bool {
        (manager as? DefaultAudiobookManager)?.sleepTimer.isActive ?? false
    }

    /// Seconds left on the active sleep timer (0 when inactive).
    public var sleepTimerRemaining: TimeInterval {
        (manager as? DefaultAudiobookManager)?.sleepTimer.timeRemaining ?? 0
    }

    /// Overall download progress (0…1) for the current audiobook's tracks —
    /// reads the toolkit playback model's published `overallDownloadProgress`.
    /// Drives the download bar in the in-app custom player.
    public var overallDownloadProgress: Float {
        playbackModel?.overallDownloadProgress ?? 0
    }

    /// Whether tracks are still downloading / decrypting in the background
    /// (progress < 1). Reads the toolkit playback model's `isDownloading`.
    public var isDownloading: Bool {
        playbackModel?.isDownloading ?? false
    }

    /// Chapter-relative playhead offset (seconds into the current chapter) —
    /// the raw value behind the toolkit player's elapsed timecode.
    public var chapterOffset: TimeInterval {
        playbackModel?.chapterPlayheadOffset ?? 0
    }

    /// Seconds remaining in the current chapter — the raw value behind the
    /// toolkit player's chapter time-left timecode.
    public var chapterTimeLeft: TimeInterval {
        playbackModel?.chapterTimeLeft ?? 0
    }

    /// Latest transient toast (bookmark-added / playback error), or `nil` when
    /// the toolkit's message is empty. The toolkit uses an empty string as its
    /// "no message" sentinel; we normalize that to `nil` for the Palace surface.
    public var toastMessage: String? {
        let message = playbackModel?.toastMessage
        return (message?.isEmpty ?? true) ? nil : message
    }

    /// Adds a bookmark at the current playback position via the toolkit
    /// playback model. Reports `nil` on success, a non-nil `Error` on failure
    /// (including "no active session" when nothing is loaded).
    public func addBookmark(completion: @escaping (Error?) -> Void) {
        guard let playbackModel else {
            completion(NSError(
                domain: "AudiobookSessionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No active audiobook session to bookmark."]
            ))
            return
        }
        playbackModel.addBookmark(completion: completion)
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
    ///     pre-return offset (HelpSpot 17988).
    public func stopPlayback(dismissPhoneUI: Bool = true, persistFinalPosition: Bool = true) async {
        Log.info(#file, "Stopping playback (dismissPhoneUI: \(dismissPhoneUI), persistFinalPosition: \(persistFinalPosition))")

        // Cancel any in-flight loader and supersede its open, so a completion
        // that lands after this stop only returns to its own caller. Without
        // the bump it would publish an error over this stop or a newer open.
        currentLoader?.cancel()
        currentLoader = nil
        loadGeneration &+= 1

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
        chapterNavigationHold.release()

        manager?.pause()
        manager?.unload()

        // Release DRM decryptor BEFORE nil-ing the manager so there is no window
        // where the decryptor could be asked to open a new Publication.
        #if LCP
        (decryptor as? LCPAudiobooks)?.releaseResources()
        #endif
        decryptor = nil

        if dismissPhoneUI {
            if let bookId = bookId {
                dismissPlayerOnPhone(bookId: bookId)
            } else if inAppPlaybackNavEnabledProvider() {
                // Flag-ON dismiss only needs the presenter cleared — it does not
                // use `bookId` (see `dismissPlayerOnPhone`). Gating the WHOLE
                // dismiss behind `let bookId` meant a nil `currentBook` at
                // teardown time (transient / already-cleared states) left the
                // mini-bar + pill on screen, so the ✕ appeared to do nothing.
                // Clear the presenter unconditionally on the flag-ON path.
                audiobookSessionPresenterProvider().clearActiveSession()
            }
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

    /// Cancels any pending throttled remote
    /// listening-position write for `bookId` by routing to the live bookmark
    /// delegate (`AudiobookBookmarkBusinessLogic`) that owns the
    /// `RemotePositionWriter`. Only cancels when `bookId` is the active
    /// session's book (a queued write can only exist for the book whose
    /// delegate is currently bound); a no-op otherwise. This is the single
    /// implementation used by both `stopPlayback` (self) and the
    /// `BookReturnService` return path (via the `AudiobookSessionManaging`
    /// protocol on `AppContainer.audiobookSession`).
    @MainActor
    func cancelPendingRemotePositionWrite(forBookId bookId: String) async {
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
    /// Forwards to the root-level presenter, which otherwise keeps the lo-res
    /// image snapshotted at `adoptPlaybackModel(_:)`.
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
        self.boundContentSource = (book.identifier, Self.contentSourceForBinding(book: book, decryptor: loaded.decryptor))
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
    /// `presentOnFirstOpen()` is called synchronously here, before the
    /// readiness-gate Task in `startPlaybackAndSyncPosition` runs, so the
    /// player shows cover art and loading state during the wait (PP-4436).
    ///
    /// `playbackModel` is optional because tests cannot easily build an
    /// `AudiobookPlaybackModel`; production always passes one.
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
        let shouldRestore = positionResolver.shouldRestoreBookmarkPosition(for: book)
        let localPosition = shouldRestore ? positionResolver.getValidLocalPosition(book: book, audiobook: loaded.audiobook) : nil
        let beginning = TrackPosition(
            track: firstTrack,
            timestamp: 0.0,
            tracks: loaded.audiobook.tableOfContents.tracks
        )
        let bookId = book.identifier

        // PP-4542: resolve the open position (preferring a newer remote
        // bookmark) before the first play, so the playhead does not jump after
        // opening. The remote lookup is bounded by `remotePositionResolveTimeout`.
        Task { @MainActor in
            guard self.currentBook?.identifier == bookId else { return }
            let initialPosition = await self.positionResolver.resolveInitialPosition(
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
    /// — and be awaited — BEFORE play, without disturbing the readiness-gate
    /// / LCP-bypass wiring below.
    @MainActor
    private func issueFirstPlay(for book: TPPBook, loaded: LoadedAudiobook, initialPosition: TrackPosition) {
        Log.debug(#file, "Opening '\(book.title)' at: track=\(initialPosition.track.key), timestamp=\(initialPosition.timestamp)")

        // PP-4963: measure where we opened against the last position the
        // playback clock saw. Observation only — the position being opened at
        // has already been decided by `resolveInitialPosition` and is not
        // altered by what this finds.
        loaded.positionTrace.evaluateRestoreGap(restoredPosition: initialPosition, in: loaded.audiobook.tableOfContents)

        // PP-4436: await player readiness before the first `play(at:)`; a play
        // issued while the engine is initializing is dropped.
        let probe = readinessProbeFactory(loaded.manager.audiobook.player)
        let command = playbackCommandFactory(loaded.manager.audiobook.player)
        let budget = readinessTimeout
        let bookId = book.identifier
        // LCP players report `isLoaded` only once playing, so the pre-play gate
        // would deadlock; LCP instead gets play-then-confirm, and the toolkit's
        // own 30s timeout covers a genuine non-start. See `PlaybackOpenPolicy`.
        let isLCPAudiobook = PlaybackOpenPolicy.decideForLoad(
            decryptor: loaded.decryptor
        ).bypassReadinessGate

        Task { @MainActor in
            loaded.playbackModel.currentLocation = initialPosition
            loaded.playbackModel.beginSaveSuppression(for: 3.0)
            if isLCPAudiobook {
                // A single play can be dropped while the LCP engine initializes,
                // so play, then confirm with bounded retries.
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


    // MARK: - Readiness gate wiring (PP-4436)

    /// Awaits readiness via the supplied probe + gate, then issues exactly
    /// one `play(at:)` through the supplied command. On timeout, surfaces
    /// the load failure on the session manager (`state = .error`,
    /// `errorPublisher.send(.playerCreationFailed)`); on any other error
    /// after readiness, the failure is logged but state is left to the
    /// toolkit's regular failure path (which will fire `playbackFailed`).
    ///
    /// `internal` so tests can drive it with a spy probe and command.
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

    // MARK: - LCP first-open reliable start

    /// LCP first-open retry budget: play, then re-issue every
    /// `lcpFirstPlayRetryInterval` until the engine reports playing or the
    /// budget runs out. Well below the toolkit's own 30s `.failed` timeout,
    /// which still reports a genuine non-start.
    ///
    /// Provisional: 3.0s/0.5s has not been measured on device.
    static let lcpFirstPlayBudget: TimeInterval = 3.0
    static let lcpFirstPlayRetryInterval: TimeInterval = 0.5

    /// LCP first-open reliable start: issue `play(at:)`, then re-issue every
    /// `retryInterval` while the engine has NOT confirmed playing, bounded by
    /// `budget`. The re-issue is suppressed as soon as `probe.isCurrentlyReady()`
    /// is true, so a playing engine is never double-started. On budget
    /// exhaustion it stays silent and defers to the toolkit's 30s `.failed`.
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

    /// Passthrough: TOC collapse lives in the toolkit's
    /// `AudiobookTableOfContents`. A second collapse here would number chapters
    /// differently from the toolkit's currentChapter / saved position.
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



    /// PP-4542: the upfront LCP content gate. If the audiobook is openable but
    /// its `.lcpa` is not on disk, trigger the content download and await it;
    /// otherwise return `.proceed`. Triggering first matters because a
    /// license-only book may have no download in flight. Inputs and the await
    /// are injected for tests; identity re-check and UI stay in the caller.
    func gateOnLCPContentDownload(
        for book: TPPBook,
        isColdLoadRecovery: Bool,
        canOpenLCPBook: Bool,
        contentIsLocal: Bool,
        awaitContentLanding: (String) async -> Bool = { bookId in
            await AudiobookSessionManager.awaitAudiobookContentLocal(bookId)
        }
    ) async -> ContentGateResult {
        guard Self.shouldTriggerContentDownloadBeforeOpen(
            isColdLoadRecovery: isColdLoadRecovery,
            canOpenLCPBook: canOpenLCPBook,
            contentIsLocal: contentIsLocal,
            streamingEnabled: lcpStreamingEnabledProvider()
        ) else {
            // PP-5135: not blocking is not the same as not fetching. With
            // streaming ON this is the common path for a book whose `.lcpa` never
            // arrived, and returning here without a trigger is exactly how such a
            // book stayed content-less for the life of the loan — playable only
            // while online, despite being shelved as Downloaded. Fire the
            // idempotent fetch and proceed immediately; the patron streams now and
            // the archive lands behind them, so the NEXT open works offline.
            if Self.shouldFetchContentBeforeOpen(
                isColdLoadRecovery: isColdLoadRecovery,
                canOpenLCPBook: canOpenLCPBook,
                contentIsLocal: contentIsLocal
            ) {
                // Honor `downloadOnlyOnWiFi` here, separately from the gate
                // predicate: `networkValidationError` passes a
                // `.downloadSuccessful` book, so without this an open on
                // cellular would start a large transfer (as
                // `DownloadStartReducer.reduceRegular` refuses with .failWifi).
                let reachability = reachabilityProvider()
                if LocalBookContentService.backgroundFetchAllowed(
                    isConnectedToNetwork: reachability.isConnectedToNetwork(),
                    isOnWiFi: reachability.isOnWiFi,
                    downloadOnlyOnWiFi: settings.downloadOnlyOnWiFi
                ) {
                    Log.info(#file, "PP-5135: LCP content missing and streaming is ON — fetching the .lcpa in the background so the book works offline, without blocking this open")
                    lcpContentDownloadTrigger(book)
                } else {
                    Log.info(#file, "PP-5135: LCP content missing, but a background fetch is not allowed right now (offline, or cellular with download-only-on-WiFi set) — opening anyway; the fetch retries on a later open")
                }
            }
            return .proceed
        }

        Log.info(#file, "LCP audiobook content not on disk — TRIGGERING content download before opening (PP-4542 gate / 323-Cause-1)")
        // TRIGGER (not just poll): idempotent — no-ops if the .lcpa already
        // exists or a download is already in flight. This is exactly what
        // BookRegistrySync's self-heal uses and it reliably lands the .lcpa.
        lcpContentDownloadTrigger(book)

        let landed = await awaitContentLanding(book.identifier)
        return landed ? .landedAfterTrigger : .contentUnavailable
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

    /// Awaits `account.awaitReady()` so nil `Account.details` during cold
    /// launch is not read as "no auth required" (see
    /// docs/architecture/account-state-machine.md). The 20s session-manager
    /// timeout is the only timeout on this path.
    // `internal` for AudiobookPositionRestoreTests.
    func isUserAuthenticated() async -> Bool {
        guard let account = accountsManager.currentAccount else {
            return Self.missingRegistryRowAuthFallback(libraryID: accountsManager.currentAccountId, hasStoredCredentials: accountsManager.currentUserAccount.hasCredentials())
        }

        let details: AccountDetails
        do {
            details = try await account.awaitReady()
        } catch {
            // PP-5135: readiness usually fails because the device is offline.
            // Fall back to stored credentials (keychain, no network) so a
            // signed-in patron can play a downloaded book; see
            // `offlineAuthFallback`.
            let hasCredentials = accountsManager.userAccount(for: account.uuid).hasCredentials()
            let authed = Self.offlineAuthFallback(error: error, hasStoredCredentials: hasCredentials)
            Log.warn(#file, "isUserAuthenticated: awaitReady failed (\(error)) — falling back to stored credentials: hasCredentials=\(hasCredentials) authed=\(authed)")
            return authed
        }

        guard let defaultAuth = details.defaultAuth else {
            return true // No auth required
        }

        if !defaultAuth.needsAuth {
            return true
        }

        return accountsManager.currentUserAccount.hasCredentials()
    }

    /// Internal rather than `private` as a test seam; no test drives it yet
    /// (PP-4951).
    func handleManagerState(_ managerState: AudiobookManagerState) {
        guard let bookId = currentBook?.identifier else { return }

        // Single site, so the state→play-state mapping is reachable by a test.
        // See `AudiobookPlaybackLifecycleSignal.playState(for:bookId:)`; a chapter
        // ending returns nil and leaves both alone (PP-4951). Publishing stays in
        // the arms below, each at the point it always published.
        if let applied = AudiobookPlaybackLifecycleSignal.playState(for: managerState, bookId: bookId) {
            (isPlaying, state) = applied
        }

        switch managerState {
        case .playbackBegan(let position):
            Log.debug(#file, "Playback began at: \(position.timestamp)")
            hasEverStartedPlayback = true
            // PP-5241: the re-established session played; close the episode.
            mediaServicesResetRecovery.handlePlaybackBegan(bookId: bookId)
            currentPosition = position
            updateNowPlayingInfo(position: position)
            playbackStatePublisher.send(state)

        case .playbackStopped(let position):
            Log.debug(#file, "Playback stopped at: \(position.timestamp)")
            currentPosition = position
            nowPlayingCoordinator?.setPlaybackState(playing: false)
            playbackStatePublisher.send(state)

        case .playbackFailed(let position, let error):
            // One call yields both the published state and the recovery that
            // runs, from one context, so the two cannot disagree. The published
            // state is NOT derivable from the recovery case — see
            // `AudiobookPlaybackRecoveryReducer`'s header for which case breaks
            // that implication and why.
            let outcome = playbackFailureOutcome(for: currentBook, bookId: bookId, error: error)
            // PP-4542 (A): if we're already parked awaiting this book's content
            // download (a fresh-borrow streaming failure), swallow the streaming
            // player's follow-on failure storm. Without this, a second
            // `.playbackFailed` slips past the auto-reopen guard (alreadyAttempted
            // is now true) and dead-ends to the "Unavailable" alert while the
            // await is still in flight — which is exactly what defeated the wait
            // in the field repro.
            guard case .publish(let keepsPlayerLoading, let recovery) = outcome else {
                Log.info(#file, "Ignoring follow-on playback failure for \(bookId) — a content download (PP-4542) or an OverDrive re-fulfilment (PP-4967) is in flight")
                return
            }

            // PP-5241: a media-services reset (-11819) starts a recovery, and
            // while one runs the dead player's follow-on failures are swallowed.
            // Read `isPlaying` here, before this arm clears it. The reset itself
            // is still recorded, so -11819 stays measurable in Crashlytics; only
            // the dead player's follow-on failures go unrecorded.
            if let book = currentBook,
               mediaServicesResetRecovery.handlePlaybackFailure(
                   book: book,
                   error: error,
                   resumePlaying: Self.mediaServicesResetResumePlaying(isPlaying: isPlaying, state: state, bookId: bookId),
                   record: { sendPlaybackFailureRecordIfNew(error: error, position: position, bookId: bookId) }) {
                return
            }

            Log.error(#file, "Playback failed at position: \(String(describing: position))")
            isPlaying = false

            // While a recovery is in flight the player holds a `.loading`
            // (recovering) state so the presenter shows the loading shell
            // instead of flashing an error dialog that the recovery then
            // immediately undoes — the error-then-recover flicker patrons saw
            // on the OverDrive expired-URL path (PP-4800). Only a terminal
            // failure publishes `.error`.
            state = keepsPlayerLoading
                ? .loading(bookId: bookId)
                : .error(bookId: bookId, message: "Playback failed")
            playbackStatePublisher.send(state)

            // Record a Crashlytics non-fatal with the error code, HTTP status,
            // track URL, and book id. PP-5242: repeats within a minute are not
            // re-sent; see `PlaybackFailureRecordDeduplicator`.
            sendPlaybackFailureRecordIfNew(error: error, position: position, bookId: bookId)

            // Spend the bound here, once, for whichever recovery starts. After
            // the media-services check above, which can claim the failure
            // without starting any of these. Not reached by tests: this arm
            // needs `currentBook`, which only the full open flow sets.
            // `AudiobookOverdriveRefulfillWiringTests` drives the method it
            // calls, and the recovery's own re-open below, by hand.
            noteRecoveryStarted(recovery, for: bookId)

            switch recovery {
            case .samlReauth:
                // PP-3703: a 401 on the CM fulfill link after SAML session
                // expiry. The reducer decides whether to ask; AuthCoordinator
                // picks the re-auth mechanism.
                guard let book = currentBook else { return }
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

            case .overdriveRefulfill:
#if FEATURE_OVERDRIVE
                // PP-4800: expired OverDrive signed URLs. Re-fulfill through the
                // download path (see `recoverExpiredOverdriveByRefulfilling`), which
                // sends the OverDrive auth headers; the loader path would 401.
                // One attempt per session.
                guard let book = currentBook else { return }
                Log.info(#file, "OverDrive audiobook playback failed on an expired signed URL — re-fulfilling via the download center and re-opening")
                Task { [weak self] in
                    guard let self else { return }
                    guard self.currentBook?.identifier == book.identifier else { return }
                    await self.recoverExpiredOverdriveByRefulfilling(book)
                }
#endif
                return

            case .overdriveRefulfillExhausted:
                // PP-4967: the fresh link from this open's re-fulfilment failed
                // the same way. Another re-open replays it, so stop and tell the
                // patron what to do.
                Log.info(#file, "OverDrive audiobook still failing on its link after re-fulfilment — dismissing with the link-renewal message")
                errorPublisher.send(.unknown("Playback failed"))
                Task { [weak self] in
                    await self?.dismissAndPresentOverdriveLinkRenewalFailed()
                }
                return

            case .bearerTokenRefulfill:
                // HelpSpot #18471: mid-listen expired entitlement on a bearer-token
                // audiobook. Re-open with forceRefulfill for a fresh manifest; no
                // re-borrow, so a revoked loan fails again into the normal error
                // UX. One attempt per book per session.
                guard let book = currentBook else { return }
                Log.info(#file, "Bearer-token audiobook playback failed on an expired entitlement — re-fulfilling fresh manifest and re-opening (323-Cause-3)")
                Task { [weak self] in
                    guard let self else { return }
                    guard self.currentBook?.identifier == book.identifier else { return }
                    _ = await self.openAudiobook(book, startPlaying: true, forceRefulfill: true)
                }
                return

            case .coldLoadAwaitContentThenReopen:
                // PP-4542: a cold-load failure while content is still downloading.
                // Re-opening the same stream fails again, so hold the loading
                // state and re-open from the local file once it lands. Does not
                // stack with the upfront LCP gate in openAudiobook, so the wait
                // is a single 180s window.
                guard let book = currentBook else { return }
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

            case .coldLoadReopen:
                // PP-4542: a first cold open of an LCP audiobook can fail with
                // rangeOutOfBounds before the package is fully materialized
                // (Readium 3.9.0, PP-4340). Re-open once, silently, before any
                // error; the toolkit's LCPResourceLoaderDelegate retry is the
                // primary fix.
                guard let book = currentBook else { return }
                Log.info(#file, "Cold-load failure detected — attempting one automatic re-open before surfacing alert")
                Task { [weak self] in
                    guard let self else { return }
                    guard self.currentBook?.identifier == book.identifier else { return }
                    _ = await self.openAudiobook(book, startPlaying: true, forceRefulfill: false, isColdLoadRecovery: true)
                }
                return

            case .terminal(let dismissAndAlert):
                errorPublisher.send(.unknown("Playback failed"))

                // Cold-load failure that persisted past the one silent auto-reopen
                // (or a failure after playback had already started): dismiss the
                // player and surface an honest "not playable right now" alert.
                // NOT a retry offer — we already retried once silently; a button
                // would just invite rage-tapping for no outcome. The user can
                // re-tap the book themselves; that's natural UX, not a fake
                // affordance.
                if dismissAndAlert {
                    Log.info(#file, "Cold-load failure persisted after auto re-open — dismissing player UI and showing unavailable alert")
                    Task { [weak self] in
                        guard let self else { return }
                        await self.dismissAndPresentColdLoadUnavailable()
                    }
                }
            }


        case .playbackCompleted(let position):
            // A chapter ended, not the book (PP-4951): audio continues into the
            // next chapter, so play state is left untouched. Do not set
            // `isPlaying = false` or publish a state here. This arm is not driven
            // by tests (`handleManagerState` needs the full open flow); the
            // mapping itself is pinned by `AudiobookChapterCompletionPauseTests`.
            Log.info(#file, "Chapter completed at: \(position.timestamp)")
            currentPosition = position
            // No `playbackStatePublisher.send`: play state did not move, and a
            // duplicate emission per chapter would be a new signal to every
            // subscriber (CarPlay, the presenter) that nothing asked for.

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
        if let newChapter = chapterNavigationHold.chapterToPublish(
            from: manager?.currentChapter, replacing: currentChapter
        ) {
            currentChapter = newChapter
            chapterUpdatePublisher.send((chapters: currentChapters, current: currentChapter))
        }

        // Update Now Playing (debounced in coordinator)
        updateNowPlayingInfo(position: position)
    }

    /// Sends one playback-failure report, unless PP-5242's deduplicator has
    /// already sent the same failure within its window.
    private func sendPlaybackFailureRecordIfNew(error: Error?, position: TrackPosition?, bookId: String) {
        let contentSource = Self.contentSource(bound: boundContentSource, failingBookId: bookId)
        if let record = Self.playbackFailureRecordToSend(
            error: error, position: position, bookId: bookId, contentSource: contentSource,
            deduplicator: &playbackFailureDeduplicator, now: Date()) {
            Self.sendPlaybackFailureRecord(record)
        }
    }

    /// The PP-5241 recovery host's only session-state write, from outside this
    /// file where `state` and `isPlaying` are not writable. It can only mark
    /// the session not playing: the recovery publishes its loading shell and
    /// its terminal error through here, never a playing state.
    func publishMediaServicesResetState(_ newState: AudiobookSessionState) {
        isPlaying = false
        state = newState
        playbackStatePublisher.send(state)
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
