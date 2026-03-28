//
//  ReadingActivity.swift
//  Palace
//
//  Created for Social Features — reading activity feed events.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A single event in the user's reading activity feed.
struct ReadingActivity: Codable, Identifiable, Equatable {

    /// The kind of activity that occurred.
    enum ActivityType: String, Codable, CaseIterable {
        case startedReading
        case finishedBook
        case earnedBadge
        case addedToCollection
        case wroteReview
    }

    /// Unique identifier for this event.
    let id: UUID

    /// What happened.
    let type: ActivityType

    /// The book associated with the activity, if any.
    let bookID: String?

    /// The book title (denormalized for display).
    let bookTitle: String?

    /// When the activity occurred.
    let timestamp: Date

    /// Additional context (e.g. badge name, collection name, rating).
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        type: ActivityType,
        bookID: String? = nil,
        bookTitle: String? = nil,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.timestamp = timestamp
        self.metadata = metadata
    }

    // MARK: - Display Helpers

    /// Human-readable description of this activity.
    var displayText: String {
        switch type {
        case .startedReading:
            if let title = bookTitle {
                return "Started reading \(title)"
            }
            return "Started reading a book"
        case .finishedBook:
            if let title = bookTitle {
                return "Finished \(title)"
            }
            return "Finished a book"
        case .earnedBadge:
            let badgeName = metadata["badgeName"] ?? "a badge"
            return "Earned \(badgeName)"
        case .addedToCollection:
            let collectionName = metadata["collectionName"] ?? "a collection"
            if let title = bookTitle {
                return "Added \(title) to \(collectionName)"
            }
            return "Added a book to \(collectionName)"
        case .wroteReview:
            if let title = bookTitle {
                return "Reviewed \(title)"
            }
            return "Wrote a review"
        }
    }

    /// SF Symbol name for this activity type.
    var iconName: String {
        switch type {
        case .startedReading:
            return "book.fill"
        case .finishedBook:
            return "checkmark.circle.fill"
        case .earnedBadge:
            return "star.circle.fill"
        case .addedToCollection:
            return "folder.badge.plus"
        case .wroteReview:
            return "text.quote"
        }
    }
}
