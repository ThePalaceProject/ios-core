//
//  CarPlayAudiobookBridge.swift
//  Palace
//
//  Thin adapter bridging CarPlay UI to AudiobookSessionManager.
//  All state management is delegated to AudiobookSessionManager.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import MediaPlayer
import PalaceAudiobookToolkit
import UIKit
import PalaceLogging
import PalaceBookModel

// MARK: - CarPlayPlaybackError

/// Error types for CarPlay playback failures
enum CarPlayPlaybackError: Error {
    case authenticationRequired
    case networkError
    case drmError
    case notDownloaded
    case unknown
    /// The open returned `.alreadyLoading`: a stop or a newer open replaced it
    /// (PP-5302), the same book was already loading, or the LCP content gate
    /// found a newer open. Nothing to report to the patron.
    case superseded

    init(from sessionError: AudiobookSessionError) {
        switch sessionError {
        case .notAuthenticated:
            self = .authenticationRequired
        case .notDownloaded:
            self = .notDownloaded
        case .networkUnavailable:
            self = .networkError
        case .alreadyLoading:
            self = .superseded
        default:
            self = .unknown
        }
    }

    /// The CarPlay alert for this failure, or nil when none should be shown.
    var alertContent: (title: String, message: String)? {
        switch self {
        case .authenticationRequired:
            return (Strings.CarPlay.Error.authRequired, Strings.CarPlay.Error.authMessage)
        case .networkError:
            return (Strings.CarPlay.Error.offline, Strings.CarPlay.Error.offlineMessage)
        case .drmError:
            return (Strings.CarPlay.Error.playbackFailed, Strings.CarPlay.Error.drmMessage)
        case .notDownloaded:
            return (Strings.CarPlay.Error.notDownloaded, Strings.CarPlay.Error.downloadRequired)
        case .unknown:
            return (Strings.CarPlay.Error.playbackFailed, Strings.CarPlay.Error.tryAgain)
        case .superseded:
            return nil
        }
    }
}

// MARK: - CarPlayAuthHelper

/// Shared authentication helper for CarPlay components.
enum CarPlayAuthHelper {
    /// Checks if the user is authenticated with the current library.
    ///
    /// Awaits `Account.awaitReady()` so unloaded account details during cold
    /// launch are not read as "no auth required". On failure it reports
    /// unauthenticated so CarPlay shows its "auth required" alert (CarPlay
    /// cannot present sign-in). The downstream 20s session-manager timeout
    /// bounds the wait.
    static func isAuthenticated(accountsManager: AccountsManager = AppContainer.production().accountsManager) async -> Bool {
        guard let account = accountsManager.currentAccount else {
            // Shares the audiobook gate's policy rather than restating it — CarPlay
            // cannot present a sign-in UI, so a divergence here strands a signed-in
            // patron on the head unit with no route to recovery.
            return AudiobookSessionManager.missingRegistryRowAuthFallback(libraryID: accountsManager.currentAccountId, hasStoredCredentials: accountsManager.currentUserAccount.hasCredentials())
        }

        let details: AccountDetails
        do {
            details = try await account.awaitReady()
        } catch {
            Log.warn(#file, "CarPlayAuthHelper.isAuthenticated: awaitReady failed — surfacing as unauthenticated: \(error)")
            return false
        }

        guard let defaultAuth = details.defaultAuth else {
            return true
        }

        if !defaultAuth.needsAuth {
            return true
        }

        return accountsManager.currentUserAccount.hasCredentials()
    }
}

// MARK: - CarPlayAudiobookBridge

/// Thin adapter bridging CarPlay UI to AudiobookSessionManager.
/// Provides CarPlay-specific publishers and convenience methods.
@MainActor
final class CarPlayAudiobookBridge: ObservableObject {

    // MARK: - Types

    typealias PlaybackResult = Result<Void, CarPlayPlaybackError>
    typealias PlaybackCompletion = (PlaybackResult) -> Void

    enum PlaybackState {
        case playing
        case paused
        case stopped
    }

    // MARK: - Properties

    private let sessionManager: AudiobookSessionManaging
    private var cancellables = Set<AnyCancellable>()

    /// Publisher for CarPlay UI to observe playback state changes
    let playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()

    /// Publisher for chapter updates
    let chapterUpdatePublisher = PassthroughSubject<[Chapter], Never>()

    /// Publisher for errors
    let errorPublisher = PassthroughSubject<CarPlayPlaybackError, Never>()

    // MARK: - Computed Properties

    var currentBook: TPPBook? {
        sessionManager.currentBook
    }

    var currentChapters: [Chapter]? {
        sessionManager.currentChapters.isEmpty ? nil : sessionManager.currentChapters
    }

    var currentChapter: Chapter? {
        sessionManager.currentChapter
    }

    var isPlaying: Bool {
        sessionManager.isPlaying
    }

    // MARK: - Initialization

    init(sessionManager: AudiobookSessionManaging? = nil) {
        // Resolve through AppContainer's cached factory so production and tests
        // share the same session-manager identity; pass a mock to override.
        self.sessionManager = sessionManager ?? AppContainer.production().audiobookSession
        setupSubscriptions()
        Log.info(#file, "CarPlayAudiobookBridge initialized")
    }

    // MARK: - Public API

    /// Initiates audiobook playback for CarPlay
    func playAudiobook(_ book: TPPBook, completion: @escaping PlaybackCompletion) {
        Log.info(#file, "CarPlay: Starting playback for '\(book.title)'")

        Task {
            let result = await sessionManager.openAudiobook(book, startPlaying: true)

            switch result {
            case .success:
                Log.info(#file, "CarPlay: Playback started successfully")
                completion(.success(()))

            case .failure(let error):
                Log.error(#file, "CarPlay: Playback failed - \(error.localizedDescription)")
                let carPlayError = CarPlayPlaybackError(from: error)
                completion(.failure(carPlayError))
            }
        }
    }

    /// Resumes playback
    func play() {
        sessionManager.play()
    }

    /// Pauses playback
    func pause() {
        sessionManager.pause()
    }

    /// Cycles through playback rates
    func cyclePlaybackRate() {
        _ = sessionManager.cyclePlaybackRate()
    }

    /// Skips to a specific chapter
    func skipToChapter(at index: Int) {
        sessionManager.skipToChapter(at: index)
    }

    /// Stops playback and cleans up.
    /// Note: This does NOT dismiss the phone UI - the user may want to continue using the phone app.
    /// Phone UI is only dismissed when switching to a different book (handled in openAudiobook).
    func stopCurrentPlayback() {
        Task {
            // CarPlay-initiated stop: the user is intentionally ending this
            // session, so persist the final position (default behavior).
            await sessionManager.stopPlayback(dismissPhoneUI: false, persistFinalPosition: true)
        }
        Log.info(#file, "CarPlay: Stopped playback")
    }

    /// Dismisses the audiobook view on the phone.
    ///
    /// Minimizes the presenter: the session stays active and the mini-player
    /// stays visible. CarPlay disconnect must never stop phone playback.
    ///
    /// We use the AppContainer-resolved presenter so production and any
    /// `withAudiobookSessionPresenter(_:)` test-seam override share the
    /// same instance the rest of the app sees.
    func dismissBookOnPhone() {
        Log.info(#file, "CarPlay: Dismissing book view on phone via presenter.minimize()")
        let presenter = AppContainer.production().audiobookSessionPresenter
        presenter.minimize()
    }

    /// Checks if user is authenticated; async because it awaits account
    /// readiness.
    func isAuthenticated() async -> Bool {
        await CarPlayAuthHelper.isAuthenticated()
    }

    // MARK: - Private Methods

    private func setupSubscriptions() {
        // Subscribe to session manager state changes
        sessionManager.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleSessionState(state)
            }
            .store(in: &cancellables)

        // Subscribe to chapter updates
        sessionManager.chapterUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (chapters, _) in
                self?.chapterUpdatePublisher.send(chapters)
            }
            .store(in: &cancellables)

        // Subscribe to errors
        sessionManager.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorPublisher.send(CarPlayPlaybackError(from: error))
            }
            .store(in: &cancellables)
    }

    private func handleSessionState(_ state: AudiobookSessionState) {
        switch state {
        case .playing:
            Log.debug(#file, "CarPlay: State changed to playing")
            playbackStatePublisher.send(.playing)

        case .paused:
            Log.debug(#file, "CarPlay: State changed to paused")
            playbackStatePublisher.send(.paused)

        case .idle, .error:
            Log.debug(#file, "CarPlay: State changed to stopped")
            playbackStatePublisher.send(.stopped)
            case .loading:
            Log.debug(#file, "CarPlay: State changed to loading")
            // Don't send state change for loading - wait for actual playback
        }
    }
}

// MARK: - NavigationCoordinator Extension

extension NavigationCoordinator {
    /// Retrieves the stored AudiobookPlaybackModel for a given book ID
    func getAudioModel(forBookId bookId: String) -> AudiobookPlaybackModel? {
        resolveAudioModel(for: BookRoute(id: bookId))
    }
}
