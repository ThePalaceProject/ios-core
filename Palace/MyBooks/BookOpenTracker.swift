//
//  BookOpenTracker.swift
//  Palace
//
//  Records when the user last opened each book (audiobook or ebook), as a
//  `[bookId: Date]` map in `UserDefaults`. It was the sort key for the catalog
//  "Continue" rows (removed in PP-4910) and is currently write-only.
//
//  EPUB/PDF locations carry no `timeStamp`, so without this a "last opened"
//  sort would fall back to `book.updated`, the catalog's update date.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Posted on the default notification center each time
/// `BookOpenTracker.recordOpened(_:at:)` records an open, with the book id in
/// `userInfo["bookId"]`.
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
