//
//  MediaServicesResetRecovery.swift
//  Palace
//
//  PP-5241: recover an audiobook session after iOS resets its media services.
//  After a mediaserverd restart every AVFoundation object is invalid; the player
//  fails with AVError -11819, often followed by playerNotReady, and the session
//  posts mediaServicesWereResetNotification, in either order. A playing patron is
//  re-opened through the existing recovery path; a paused one gets a teardown that
//  does not persist position (see `mediaServicesResetReestablish`).
//

import AVFoundation
import Combine
import Foundation
import PalaceBookModel
import PalaceLogging

// MARK: - Classifier

enum MediaServicesReset {

    /// How many `NSUnderlyingErrorKey` links the classifier follows. The field
    /// shapes are one or two deep; the bound only stops a pathological chain.
    static let maxUnderlyingDepth = 8

    /// True when `error`, or an error in its `NSUnderlyingErrorKey` chain, is
    /// AVFoundationErrorDomain -11819 (`AVError.mediaServicesWereReset`).
    nonisolated static func isMediaServicesReset(_ error: Error?) -> Bool {
        var current = error.map { $0 as NSError }
        var depth = 0
        while let nsError = current, depth <= maxUnderlyingDepth {
            if nsError.domain == AVFoundationErrorDomain,
               nsError.code == AVError.Code.mediaServicesWereReset.rawValue {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}

// MARK: - State machine

/// Where the current reset episode stands.
enum MediaServicesResetRecoveryPhase: Equatable {
    /// No episode.
    case idle
    /// A reset was seen for `bookId` and the session is being re-established.
    /// Every failure for that book is swallowed; further reset signals are
    /// the same episode.
    case recovering(bookId: String)
    /// The session was re-established. Holds the one-recovery-per-episode
    /// bound until the new session plays or the patron starts a fresh open:
    /// a -11819 from the new session in this window falls through to today's
    /// failure handling instead of starting a loop.
    case recovered(bookId: String)

    var bookId: String? {
        switch self {
        case .idle: return nil
        case .recovering(let id), .recovered(let id): return id
        }
    }
}

enum MediaServicesResetRecoveryEvent: Equatable {
    /// `AVAudioSession.mediaServicesWereResetNotification`. `loadedBookId` is
    /// the book with a bound player, or nil when nothing is loaded.
    case resetNotification(loadedBookId: String?)
    /// `.playbackFailed` classified by `MediaServicesReset.isMediaServicesReset`.
    case resetFailure(bookId: String)
    /// Any other `.playbackFailed` (in an episode: the follow-on storm).
    case otherFailure(bookId: String)
    case recoverySucceeded(bookId: String)
    case recoveryFailed(bookId: String)
    case playbackBegan(bookId: String)
    /// A fresh, patron-initiated open (a different book, or the same one
    /// re-tapped). Ends any episode.
    case sessionEnded

    var bookId: String? {
        switch self {
        case .resetNotification(let id): return id
        case .resetFailure(let id), .otherFailure(let id),
             .recoverySucceeded(let id), .recoveryFailed(let id),
             .playbackBegan(let id):
            return id
        case .sessionEnded: return nil
        }
    }
}

enum MediaServicesResetRecoveryEffect: Equatable {
    case none
    /// Enter recovery for `bookId`. For a failure event this also means the
    /// failure is handled (not shown).
    case startRecovery(bookId: String)
    /// The failure is handled: do not run today's failure handling.
    case swallow
    /// The failure is not ours: run today's failure handling.
    case passThrough
    /// The recovery did not re-establish the session: surface today's
    /// terminal error.
    case failTerminally(bookId: String)
}

/// Pure transition function. The full states x events table is written out
/// and asserted cell by cell in `MediaServicesResetRecoveryTableTests`.
enum MediaServicesResetRecoveryReducer {

    static func reduce(
        _ phase: MediaServicesResetRecoveryPhase,
        _ event: MediaServicesResetRecoveryEvent
    ) -> (MediaServicesResetRecoveryPhase, MediaServicesResetRecoveryEffect) {
        // A phase that names a different book than the event is stale: its
        // book is no longer the session's book. Evaluate the event as if idle.
        // Except a completion: it names the book its recovery task was started
        // for, so a mismatch means that task was superseded, and its result
        // must not move the live episode.
        var phase = phase
        if let phaseBook = phase.bookId, let eventBook = event.bookId, phaseBook != eventBook {
            switch event {
            case .recoverySucceeded, .recoveryFailed:
                return (phase, .none)
            default:
                phase = .idle
            }
        }

        switch (phase, event) {
        case (_, .sessionEnded):
            return (.idle, .none)

        case (.idle, .resetNotification(let loaded)):
            guard let loaded else { return (.idle, .none) }
            return (.recovering(bookId: loaded), .startRecovery(bookId: loaded))
        case (.recovering, .resetNotification), (.recovered, .resetNotification):
            return (phase, .none)

        case (.idle, .resetFailure(let id)):
            return (.recovering(bookId: id), .startRecovery(bookId: id))
        case (.recovering, .resetFailure), (.recovering, .otherFailure):
            return (phase, .swallow)
        case (.recovered, .resetFailure), (.recovered, .otherFailure), (.idle, .otherFailure):
            return (phase, .passThrough)

        case (.recovering(let id), .recoverySucceeded):
            return (.recovered(bookId: id), .none)
        case (.recovering(let id), .recoveryFailed):
            return (.idle, .failTerminally(bookId: id))
        case (.recovered, .playbackBegan):
            return (.idle, .none)

        case (.idle, .recoverySucceeded), (.idle, .recoveryFailed), (.idle, .playbackBegan),
             (.recovered, .recoverySucceeded), (.recovered, .recoveryFailed),
             (.recovering, .playbackBegan):
            return (phase, .none)
        }
    }
}

// MARK: - Coordinator

/// What the host reports about the session a reset notification would recover.
struct MediaServicesResetSession {
    let book: TPPBook
    /// Re-open and play (true), or tear down the dead session (false).
    let resumePlaying: Bool
}

/// The session owner the coordinator recovers through. Implemented by
/// `AudiobookSessionManager`; tests supply a spy.
@MainActor
protocol MediaServicesResetRecoveryHost: AnyObject {
    /// The session to recover when a reset notification arrives, or nil when
    /// no player is bound.
    func mediaServicesResetLoadedSession() -> MediaServicesResetSession?
    /// Save the last position the session saw from the live player, before
    /// anything is torn down. The rebuild restores the last PERSISTED position,
    /// and the periodic autosave writes only every 15 s, so skipping this loses
    /// up to 15 s. It uses the session's cached position, never a fresh read
    /// from the player: after a real reset the player is dead and may report 0.
    func mediaServicesResetPersistLastKnownPosition(bookId: String)
    /// Show the session as loading while it recovers.
    func mediaServicesResetEnterRecovering(bookId: String)
    /// Re-establish the session. Returns whether it was re-established.
    func mediaServicesResetReestablish(book: TPPBook, resumePlaying: Bool) async -> Bool
    /// The recovery failed: surface today's terminal playback error.
    func mediaServicesResetFailTerminally(bookId: String)
}

/// Observes media-services resets, de-duplicates the two reset signals into
/// one recovery per episode, and swallows the dead player's follow-on
/// failures while that recovery runs.
@MainActor
final class MediaServicesResetRecovery {

    weak var host: MediaServicesResetRecoveryHost?

    private(set) var phase: MediaServicesResetRecoveryPhase = .idle
    /// The book whose current episode already produced its one crash report.
    /// Cleared when the episode ends (the phase returns to `.idle`).
    private var reportedEpisodeBookId: String?
    /// Increments per started recovery. A recovery task can outlive its
    /// episode (the session ended mid-recovery and a new reset started a new
    /// episode for the same book), so a completion applies only if no newer
    /// recovery has started since.
    private var recoveryGeneration = 0

    /// The in-flight recovery, exposed so tests can await its completion.
    private(set) var recoveryTask: Task<Void, Never>?

    private var observation: AnyCancellable?

    init(notificationCenter: NotificationCenter) {
        // `object: nil`: AVAudioSession posts with its shared instance as the
        // object; matching on nil keeps this independent of which instance.
        // The sink runs on the posting thread, which Apple does not promise is
        // main, so hop when it is not. `@Sendable` keeps the closure
        // nonisolated: formed inside this `@MainActor` init it would otherwise
        // be inferred main-actor-isolated, and an off-main post would trip the
        // runtime isolation check (the #1218 crash class).
        observation = notificationCenter
            .publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { @Sendable [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.handleResetNotification() }
                } else {
                    // The main queue, not a Task: it runs blocks in order, so
                    // anything enqueued on it after this post runs after the
                    // recovery has started. The off-main test joins on that.
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.handleResetNotification() }
                    }
                }
            }
    }

    func handleResetNotification() {
        guard let host else { return }
        let session = host.mediaServicesResetLoadedSession()
        Log.warn(#file, "PP-5241: media services were reset (loaded book: \(session?.book.identifier ?? "none"))")
        _ = apply(.resetNotification(loadedBookId: session?.book.identifier),
                  book: session?.book,
                  resumePlaying: session?.resumePlaying ?? false)
    }

    /// Called at the top of the manager's `.playbackFailed` arm. Returns true
    /// when the failure is handled here and today's handling must not run.
    func handlePlaybackFailure(book: TPPBook, error: Error?, resumePlaying: Bool, record: () -> Void) -> Bool {
        // No host means nothing to recover through: leave the failure to
        // today's handling rather than swallowing it into a dead end.
        guard host != nil else { return false }
        let event: MediaServicesResetRecoveryEvent = MediaServicesReset.isMediaServicesReset(error)
            ? .resetFailure(bookId: book.identifier)
            : .otherFailure(bookId: book.identifier)
        let effect = apply(event, book: book, resumePlaying: resumePlaying)
        // One report per episode: PP-5242's deduplicator keys on the error's
        // structure, and one reset arrives both as -11819 and as -11800 with
        // -11819 underneath, which are two keys to it.
        if case .resetFailure = event, effect != .passThrough, effect != .none,
           reportedEpisodeBookId != book.identifier {
            reportedEpisodeBookId = book.identifier
            record()
        }
        switch effect {
        case .startRecovery, .swallow:
            if case .otherFailure = event {
                Log.info(#file, "PP-5241: ignoring follow-on playback failure for \(book.identifier) while recovering from a media services reset")
            }
            return true
        case .none, .passThrough, .failTerminally:
            return false
        }
    }

    func handlePlaybackBegan(bookId: String) {
        _ = apply(.playbackBegan(bookId: bookId), book: nil, resumePlaying: false)
    }

    func handleSessionEnded() {
        _ = apply(.sessionEnded, book: nil, resumePlaying: false)
    }

    // MARK: - Private

    private func apply(
        _ event: MediaServicesResetRecoveryEvent,
        book: TPPBook?,
        resumePlaying: Bool
    ) -> MediaServicesResetRecoveryEffect {
        let (next, effect) = MediaServicesResetRecoveryReducer.reduce(phase, event)
        phase = next
        if next == .idle { reportedEpisodeBookId = nil }
        switch effect {
        case .startRecovery(let bookId):
            if let book, book.identifier == bookId {
                startRecovery(book: book, resumePlaying: resumePlaying)
            }
        case .failTerminally(let bookId):
            Log.error(#file, "PP-5241: could not re-establish \(bookId) after a media services reset — surfacing the playback error")
            host?.mediaServicesResetFailTerminally(bookId: bookId)
        case .none, .swallow, .passThrough:
            break
        }
        return effect
    }

    private func startRecovery(book: TPPBook, resumePlaying: Bool) {
        let bookId = book.identifier
        Log.warn(#file, "PP-5241: recovering \(bookId) after a media services reset (resumePlaying: \(resumePlaying))")
        host?.mediaServicesResetPersistLastKnownPosition(bookId: bookId)
        host?.mediaServicesResetEnterRecovering(bookId: bookId)
        recoveryGeneration += 1
        let generation = recoveryGeneration
        recoveryTask = Task { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            let reestablished = await host.mediaServicesResetReestablish(book: book, resumePlaying: resumePlaying)
            Log.info(#file, "PP-5241: media services reset recovery for \(bookId) \(reestablished ? "re-established the session" : "failed")")
            guard generation == self.recoveryGeneration else {
                Log.info(#file, "PP-5241: ignoring the result of a superseded recovery for \(bookId)")
                return
            }
            _ = self.apply(reestablished ? .recoverySucceeded(bookId: bookId) : .recoveryFailed(bookId: bookId),
                           book: book,
                           resumePlaying: resumePlaying)
        }
    }
}

// MARK: - Session manager inputs

extension AudiobookSessionManager {

    /// Whether a recovery should resume playback: the patron was playing, or
    /// this book was mid-open (every production open starts playing).
    nonisolated static func mediaServicesResetResumePlaying(
        isPlaying: Bool,
        state: AudiobookSessionState,
        bookId: String
    ) -> Bool {
        if isPlaying { return true }
        if case .loading(let loadingId) = state, loadingId == bookId { return true }
        return false
    }

    /// The session a reset notification should recover: only one with a bound
    /// player. Mid-open there is no player yet; one built after the reset is
    /// valid, and if it fails anyway the -11819 failure path recovers it.
    nonisolated static func mediaServicesResetSession(
        book: TPPBook?,
        hasActiveManager: Bool,
        isPlaying: Bool,
        state: AudiobookSessionState
    ) -> MediaServicesResetSession? {
        guard let book, hasActiveManager else { return nil }
        return MediaServicesResetSession(
            book: book,
            resumePlaying: mediaServicesResetResumePlaying(isPlaying: isPlaying, state: state, bookId: book.identifier)
        )
    }
}
