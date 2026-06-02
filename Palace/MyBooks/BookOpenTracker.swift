//
//  BookOpenTracker.swift
//  Palace
//
//  Records the wall-clock timestamp at which the user opened each book
//  (audiobook OR ebook). Used by `RecentlyReadingService` to sort the
//  Continue Reading row correctly — without this, EPUB / PDF locations
//  (which don't embed a `timeStamp` in their JSON) fall back to
//  `book.updated` from the OPDS feed, which is the *catalog* update
//  date, NOT the read date. The user's "last read book is preloading
//  some other book than the last read book" symptom was caused by an
//  older-opened book that had a newer `book.updated` winning the sort.
//
//  Persistence: `UserDefaults` keyed by stable storage key. Map
//  `[String: Date]` of bookId → last-opened wall-clock date. Survives
//  app launches; no migration required (a missing entry just means we
//  fall back to the renderer-specific timestamp the same way we did
//  before this tracker existed).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Records and looks up the most-recent wall-clock open time for a
/// book. Polish-phase addition (in-app-nav-polish-2026-06-01) for the
/// user-reported "wrong last-read book" bug.
protocol BookOpenTracking {
    /// Records that the user opened the book identified by `bookId` at
    /// `date` (defaults to now). Overwrites any prior entry.
    func recordOpened(_ bookId: String, at date: Date)

    /// Returns the most-recent recorded open time for `bookId`, or
    /// `nil` if the book has never been opened (or was opened before
    /// the tracker was added).
    func lastOpened(_ bookId: String) -> Date?
}

extension BookOpenTracking {
    func recordOpened(_ bookId: String) {
        recordOpened(bookId, at: Date())
    }
}

final class BookOpenTracker: BookOpenTracking {
    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "TPPBookLastOpenedAt"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func recordOpened(_ bookId: String, at date: Date) {
        guard !bookId.isEmpty else { return }
        var dict = currentMap()
        dict[bookId] = date
        userDefaults.set(dict, forKey: storageKey)
    }

    func lastOpened(_ bookId: String) -> Date? {
        guard !bookId.isEmpty else { return nil }
        return currentMap()[bookId]
    }

    private func currentMap() -> [String: Date] {
        guard let dict = userDefaults.dictionary(forKey: storageKey) else {
            return [:]
        }
        // UserDefaults stores Date values directly when set as a
        // plist-compatible dictionary; the cast keeps non-Date values
        // out (e.g. legacy entries written as ISO strings).
        var typed: [String: Date] = [:]
        for (key, value) in dict {
            if let date = value as? Date {
                typed[key] = date
            }
        }
        return typed
    }
}
