//
//  BookOpenTracker.swift
//  Palace
//
//  Records the wall-clock timestamp at which the user opened each book
//  (audiobook OR ebook). Originally the sort key for the catalog "Continue"
//  rows (removed in PP-4910), so it is currently write-only: the reader /
//  audiobook open-paths still record into it, but nothing reads it back
//  until a future "resume" re-entry point is designed. Kept because the
//  recording lives in critical-path flows and the data is cheap to retain.
//
//  Historical rationale for existing (still valid if a reader returns): EPUB /
//  PDF locations don't embed a `timeStamp`, so without this an open would fall
//  back to `book.updated` (the *catalog* update date, not the read date) and a
//  stale-but-recently-republished book would wrongly win the "last opened" sort.
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

/// Posted on `.default` notification center every time a book open is
/// recorded via `BookOpenTracker.recordOpened(_:at:)`. The Continue
/// row's viewmodel subscribes to this so the row updates immediately
/// when the user opens a new ebook (without this, the row stayed
/// stale until the next registry-state change — user feedback:
/// "the continue cell doesn't update when user starts reading a new
/// book"). The notification carries the bookId in
/// `userInfo["bookId"]` for callers that need to filter; the
/// viewmodel currently re-derives everything, so it doesn't.
extension Notification.Name {
    static let palaceBookOpenedDidRecord = Notification.Name("PalaceBookOpenedDidRecord")
}

/// Records and looks up the most-recent wall-clock open time for a
/// book. Polish-phase addition (in-app-nav-polish-2026-06-01) for the
/// user-reported "wrong last-read book" bug.
protocol BookOpenTracking {
    /// Records that the user opened the book identified by `bookId` at
    /// `date` (defaults to now). Overwrites any prior entry. Posts
    /// `.palaceBookOpenedDidRecord` so reactive consumers (the
    /// Continue row's viewmodel) can refresh immediately.
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
    private let notificationCenter: NotificationCenter

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "TPPBookLastOpenedAt",
        notificationCenter: NotificationCenter = .default
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.notificationCenter = notificationCenter
    }

    func recordOpened(_ bookId: String, at date: Date) {
        guard !bookId.isEmpty else { return }
        var dict = currentMap()
        dict[bookId] = date
        userDefaults.set(dict, forKey: storageKey)
        notificationCenter.post(
            name: .palaceBookOpenedDidRecord,
            object: nil,
            userInfo: ["bookId": bookId]
        )
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
