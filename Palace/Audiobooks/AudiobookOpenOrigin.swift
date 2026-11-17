//
//  AudiobookOpenOrigin.swift
//  Palace
//
//  Who started an audiobook open. Each open carries exactly one origin, so the
//  duplicate-open guard, the recovery bounds and the loader's source choice all
//  read the same fact instead of separate flags a call site had to combine
//  (PP-4973).
//

import PalaceBookModel
import PalaceLogging

/// Why the session re-opened a book on its own.
enum AudiobookReopenReason: Equatable {
    /// A first play failed (PP-4542). Skips the upfront content gate: the
    /// recovery has already waited for, or found, the content.
    case coldLoad
    /// The manifest on disk is stale, so the loader fetches a fresh one
    /// (HelpSpot #18471).
    case freshManifest
    /// Re-authentication, an OverDrive re-fulfilment or a media-services reset
    /// finished and the book opens again as it was.
    case recovery
}

enum AudiobookOpenOrigin: Equatable {
    /// The patron asked for the book: Listen, CarPlay, a deep link.
    case patron
    /// A recovery inside the session re-opened the book.
    case reopen(AudiobookReopenReason)

    /// Only a patron open re-arms the per-book recovery bounds and ends a
    /// media-services-reset episode; a re-open that did either could recover
    /// without end.
    var isPatron: Bool { self == .patron }

    var fetchesFreshManifest: Bool { self == .reopen(.freshManifest) }

    var skipsContentGate: Bool { self == .reopen(.coldLoad) }

    /// Whether an open with this origin may start while the session is in
    /// `state`. A patron opening the book that is already loading is a repeated
    /// tap. A re-open is always admitted: the recovery that issued it parked
    /// the session at `.loading` for this book itself, and the load generation
    /// supersedes the load it replaces.
    func admitsOpen(of bookId: String, whileIn state: AudiobookSessionState) -> Bool {
        guard isPatron, case .loading(let loadingId) = state else { return true }
        return loadingId != bookId
    }
}

extension AudiobookOpenOrigin: CustomStringConvertible {
    var description: String {
        switch self {
        case .patron: return "patron"
        case .reopen(.coldLoad): return "cold-load re-open"
        case .reopen(.freshManifest): return "fresh-manifest re-open"
        case .reopen(.recovery): return "recovery re-open"
        }
    }
}

extension AudiobookSessionManager {
    /// Re-opens `book` for a recovery the session started. Every recovery
    /// re-opens here, so none can be refused as a repeated patron tap or re-arm
    /// the recovery bounds (PP-4973).
    @discardableResult
    func reopen(_ book: TPPBook, because reason: AudiobookReopenReason, startPlaying: Bool = true) async -> Result<Void, AudiobookSessionError> {
        let result = await openAudiobook(book, startPlaying: startPlaying, origin: .reopen(reason))
        if case .failure(let error) = result {
            Log.warn(#file, "Re-open of \(book.identifier) (\(AudiobookOpenOrigin.reopen(reason))) ended without playing: \(error)")
        }
        return result
    }
}
