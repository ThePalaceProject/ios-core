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
    /// Wall-clock timestamp used by `mostRecent` selection to decide
    /// which item the user touched last. Set to `Date()` for a live
    /// active session (because it's literally in flight right now —
    /// always wins against any reading item); set to
    /// `bookOpenTracker.lastOpened(_:)` for the cold-launch fallback
    /// (because we need an honest comparison against the reading
    /// item's `lastReadAt`).
    let lastTouchedAt: Date

    /// Identity for SwiftUI diffing is `bookId` (the active audiobook).
    /// Display fields like `isCurrentlyPlaying` legitimately flip between
    /// refreshes for the same item; comparing them here would force a
    /// row re-create on every play/pause.
    static func == (lhs: ContinueListeningItem, rhs: ContinueListeningItem) -> Bool {
        lhs.bookId == rhs.bookId
    }
}

// MARK: - ContinueRowItem

/// Type-erased polish-phase single-row "Continue" candidate. Either
/// reading or listening — whichever is most recent. Drives the
/// collapsible single-row UX (the user's "should be collapsible, and
/// maybe only show the last book" feedback).
enum ContinueRowItem: Equatable {
    case reading(ContinueReadingItem)
    case listening(ContinueListeningItem)

    var bookId: String {
        switch self {
        case .reading(let r): return r.bookId
        case .listening(let l): return l.bookId
        }
    }

    var book: TPPBook {
        switch self {
        case .reading(let r): return r.book
        case .listening(let l): return l.book
        }
    }

    var title: String { book.title ?? "" }
    var author: String { book.authors ?? "" }
}

// MARK: - ActiveSessionsViewModel

@MainActor
final class ActiveSessionsViewModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var continueReading: [ContinueReadingItem] = []
    @Published private(set) var continueListening: [ContinueListeningItem] = []

    /// Single most-recent "Continue" candidate across BOTH reading and
    /// listening. Drives the polish-phase single-row UX (the user's
    /// "should be collapsible, and maybe only show the last book"
    /// feedback). Prefers an active audiobook session (always most
    /// recent because actively in flight); falls back to the most-recent
    /// reading item; nil when neither is available.
    @Published private(set) var mostRecent: ContinueRowItem?

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

        // Debounced: the startup registry-state burst would otherwise run one
        // full myBooks scan per notification on the main thread (froze launch).
        notificationCenter
            .publisher(for: .TPPBookRegistryStateDidChange)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
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

        // Subscribe to BookOpenTracker open-record events so the
        // Continue row updates immediately when the user opens a new
        // ebook or audiobook (registry state alone doesn't change on
        // re-open, so without this the row stayed stale until the
        // next download/return/library-swap — user feedback: "the
        // continue cell doesn't update when user starts reading a
        // new book").
        notificationCenter
            .publisher(for: .palaceBookOpenedDidRecord)
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
        mostRecent = Self.deriveMostRecent(
            listening: continueListening.first,
            reading: continueReading.first
        )
    }

    /// Pure helper — picks the single "most recent" candidate by
    /// comparing wall-clock timestamps: `ContinueListeningItem
    /// .lastTouchedAt` vs `ContinueReadingItem.lastReadAt`. The bigger
    /// timestamp wins; ties go to listening because a live or
    /// fresher-by-microseconds audiobook session is more likely to
    /// match what the user expects when they tap "Continue."
    ///
    /// Live audiobook sessions are built with `lastTouchedAt = Date()`
    /// at refresh time, so they always beat any older reading entry.
    /// Cold-launch fallback audiobooks are built with the tracker's
    /// recorded open time, so they only beat a reading item if the
    /// user genuinely opened the audiobook last.
    ///
    /// Returns nil when both empty.
    ///
    /// Extracted `static` so the polish-phase tests can pin the
    /// priority without spinning up a full viewmodel + dependencies.
    static func deriveMostRecent(
        listening: ContinueListeningItem?,
        reading: ContinueReadingItem?
    ) -> ContinueRowItem? {
        switch (listening, reading) {
        case let (l?, r?):
            return l.lastTouchedAt >= r.lastReadAt ? .listening(l) : .reading(r)
        case let (l?, nil):
            return .listening(l)
        case let (nil, r?):
            return .reading(r)
        case (nil, nil):
            return nil
        }
    }

    // MARK: Internal helpers

    /// Builds zero-or-more `ContinueListeningItem` from either:
    ///   - the current audiobook session (if one is active), OR
    ///   - the most-recently-opened audiobook from the open-time tracker
    ///     (when there's no active session — typical cold-launch case).
    ///
    /// Polish-phase (in-app-nav-polish-2026-06-01): the fallback is new.
    /// Without it, on cold launch after the user previously listened to
    /// an audiobook, the Continue row's `mostRecent` falls back to any
    /// in-progress ebook (which is older than the audiobook open) —
    /// users reported: "after changing to an audiobook from an ebook
    /// and quitting the app, on reopen the ebook is the continue reading
    /// option, not the audiobook."
    private func currentListeningItems() -> [ContinueListeningItem] {
        guard listeningRowLimit > 0 else { return [] }
        if let item = activeSessionListeningItem() {
            return Array([item].prefix(listeningRowLimit))
        }
        if let item = recentlyOpenedListeningItem() {
            return Array([item].prefix(listeningRowLimit))
        }
        return []
    }

    /// The currently-active audiobook session, if any. §11 threshold:
    /// requires `> 0` seconds of playback (a paused-but-never-advanced
    /// session is not "in progress").
    private func activeSessionListeningItem() -> ContinueListeningItem? {
        guard let book = audiobookSession.currentBook else { return nil }
        let state = audiobookSession.state

        let isPlaying: Bool
        switch state {
        case .playing:
            isPlaying = true
        case .paused:
            isPlaying = false
        case .idle, .loading, .error:
            return nil
        }

        let timestamp = audiobookSession.currentPosition?.timestamp ?? 0
        guard timestamp > 0 else { return nil }

        let chapterTitle: String? = audiobookSession.currentChapter
            .map { $0.title }
            .flatMap { $0.isEmpty ? nil : $0 }

        return ContinueListeningItem(
            bookId: book.identifier,
            book: book,
            isCurrentlyPlaying: isPlaying,
            chapterTitle: chapterTitle,
            progressFraction: nil,
            progressLabel: nil,
            // Live session — set to "now" so this item always wins
            // against any reading entry. The session IS the most recent
            // touch by definition.
            lastTouchedAt: Date()
        )
    }

    /// Cold-launch fallback — the most-recently-opened audiobook per
    /// the wall-clock open tracker, surfaced as a Continue candidate
    /// (not actively playing, no chapter/progress info because there's
    /// no live session to query).
    private func recentlyOpenedListeningItem() -> ContinueListeningItem? {
        guard let entry = recentlyReadingService.recentlyOpenedAudiobook() else {
            return nil
        }
        return ContinueListeningItem(
            bookId: entry.book.identifier,
            book: entry.book,
            isCurrentlyPlaying: false,
            chapterTitle: nil,
            progressFraction: nil,
            progressLabel: nil,
            // Fallback path — use the tracker's recorded open time so
            // `deriveMostRecent` can honestly compare against the
            // reading item's lastReadAt. If the user opened an ebook
            // more recently than this audiobook, the ebook wins.
            lastTouchedAt: entry.openedAt
        )
    }
}
