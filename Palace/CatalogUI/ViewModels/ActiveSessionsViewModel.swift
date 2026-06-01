//
//  ActiveSessionsViewModel.swift
//  Palace
//
//  Drives the "Continue Reading" + "Continue Listening" rows on the
//  Catalog tab. Re-derives both arrays from `RecentlyReadingService`
//  and `AudiobookSessionManaging` whenever the registry, current
//  account, or audiobook session state changes.
//
//  No UI here — UI lives in Module B. No singletons — collaborators
//  arrive via the initializer so Module B can wire `AppContainer`
//  at integration time.
//
//  See docs/architecture/in-app-navigation-during-playback.md §6.3 + §8.
//  See .forgeos/swarms/swarm_0b7616e7/contracts/A-RecentlyReading-ActiveSessions.md.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import SwiftUI

// MARK: - ContinueListeningItem

/// A single entry in the "Continue Listening" row.
struct ContinueListeningItem: Identifiable, Equatable {
    var id: String { bookId }
    let bookId: String
    let book: TPPBook
    /// True when `AudiobookSessionManaging.state == .playing(bookId: ...)`.
    /// Module B uses this to render a pulsing playback indicator on the
    /// current title; false for `.paused` or other-book sessions.
    let isCurrentlyPlaying: Bool
    /// Optional chapter title from `AudiobookSessionManaging.currentChapter`.
    let chapterTitle: String?
    /// Optional progress fraction in [0.0, 1.0], derived from the position
    /// timestamp / current chapter duration. Nil when not derivable.
    let progressFraction: Double?
    /// Optional human-readable progress label (e.g. "12:34 / 45:00").
    /// Nil when not derivable from the audiobook session.
    let progressLabel: String?

    /// Identity for SwiftUI diffing is `bookId` (the active audiobook).
    /// Display fields like `isCurrentlyPlaying` legitimately flip between
    /// refreshes for the same item; comparing them here would force a
    /// row re-create on every play/pause.
    static func == (lhs: ContinueListeningItem, rhs: ContinueListeningItem) -> Bool {
        lhs.bookId == rhs.bookId
    }
}

// MARK: - ActiveSessionsViewModel

@MainActor
final class ActiveSessionsViewModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var continueReading: [ContinueReadingItem] = []
    @Published private(set) var continueListening: [ContinueListeningItem] = []

    // MARK: Dependencies

    private let recentlyReadingService: RecentlyReadingService
    private let audiobookSession: AudiobookSessionManaging
    private let readingRowLimit: Int
    private let listeningRowLimit: Int

    // MARK: Subscriptions

    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(
        recentlyReadingService: RecentlyReadingService,
        audiobookSession: AudiobookSessionManaging,
        notificationCenter: NotificationCenter = .default,
        readingRowLimit: Int = 1,
        listeningRowLimit: Int = 1
    ) {
        self.recentlyReadingService = recentlyReadingService
        self.audiobookSession = audiobookSession
        self.readingRowLimit = max(0, readingRowLimit)
        self.listeningRowLimit = max(0, listeningRowLimit)

        // Subscribe to registry-state changes (books added/removed/state
        // transitions) so the Continue Reading row refreshes as soon as a
        // download completes or a book is returned.
        notificationCenter
            .publisher(for: .TPPBookRegistryStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Subscribe to current-account changes (library swap) so the
        // previous account's items are immediately cleared from the row.
        notificationCenter
            .publisher(for: .TPPCurrentAccountDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Subscribe to audiobook playback state — covers play/pause
        // transitions and book swaps without forcing the user to
        // navigate away from the Catalog.
        audiobookSession.playbackStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Seed the initial state synchronously so the first SwiftUI body
        // pass sees the right values.
        refresh()
    }

    // MARK: Public API

    /// Re-derives both arrays from the current inputs. Idempotent.
    func refresh() {
        let readingCandidates = recentlyReadingService.recentlyReading()
        continueReading = Array(readingCandidates.prefix(readingRowLimit))
        continueListening = currentListeningItems()
    }

    // MARK: Internal helpers

    /// Builds zero-or-more `ContinueListeningItem` from the current
    /// audiobook session. Today we surface at most one entry (the active
    /// session), but the array shape is preserved so a future "recently
    /// listened" history can extend the row without changing the public
    /// surface.
    private func currentListeningItems() -> [ContinueListeningItem] {
        // §11 decision: threshold is `> 0` seconds. A session that has
        // never advanced past timestamp 0.0 is not "in progress" and
        // does not surface as a Continue Listening candidate.
        guard listeningRowLimit > 0 else { return [] }
        guard let book = audiobookSession.currentBook else { return [] }
        let state = audiobookSession.state

        let isPlaying: Bool
        switch state {
        case .playing:
            isPlaying = true
        case .paused:
            isPlaying = false
        case .idle, .loading, .error:
            return []
        }

        // For playing/paused states we additionally require a non-zero
        // position. A `.paused(bookId:)` session that the user just
        // opened — but never advanced — is not "in progress."
        let timestamp = audiobookSession.currentPosition?.timestamp ?? 0
        guard timestamp > 0 else { return [] }

        // `Chapter.title` is non-optional `String`; we still wrap as
        // optional so future cases (no current chapter, empty title)
        // surface as nil at the Module B consumer site.
        let chapterTitle: String? = audiobookSession.currentChapter
            .map { $0.title }
            .flatMap { $0.isEmpty ? nil : $0 }
        let item = ContinueListeningItem(
            bookId: book.identifier,
            book: book,
            isCurrentlyPlaying: isPlaying,
            chapterTitle: chapterTitle,
            progressFraction: nil,
            progressLabel: nil
        )
        return Array([item].prefix(listeningRowLimit))
    }
}
