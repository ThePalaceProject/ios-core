//
//  OfflineAction.swift
//  Palace
//
//  A queued offline action for later processing.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The type of user-initiated action queued for offline processing.
enum OfflineActionType: String, Codable, Sendable {
    case borrow
    case `return`
    case hold
    case cancelHold
}

/// The current state of an offline action.
enum OfflineActionState: String, Codable, Sendable {
    case pending
    case processing
    case failed
    case completed
}

/// A user-initiated action that was queued while offline.
struct OfflineAction: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let type: OfflineActionType
    let bookID: String
    let bookTitle: String
    let createdAt: Date
    var state: OfflineActionState
    var retryCount: Int
    let maxRetries: Int
    var lastAttemptAt: Date?
    var errorMessage: String?

    init(
        type: OfflineActionType,
        bookID: String,
        bookTitle: String,
        maxRetries: Int = 3
    ) {
        self.id = UUID()
        self.type = type
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.createdAt = Date()
        self.state = .pending
        self.retryCount = 0
        self.maxRetries = maxRetries
    }

    /// Whether this action can be retried.
    var canRetry: Bool {
        retryCount < maxRetries && state == .failed
    }

    /// The delay before the next retry attempt using exponential backoff.
    var nextRetryDelay: TimeInterval {
        pow(2.0, Double(retryCount)) * 1.0 // 1s, 2s, 4s
    }

    /// A human-readable description of this action.
    var displayDescription: String {
        switch type {
        case .borrow: return "Borrow \"\(bookTitle)\""
        case .return: return "Return \"\(bookTitle)\""
        case .hold: return "Place hold on \"\(bookTitle)\""
        case .cancelHold: return "Cancel hold on \"\(bookTitle)\""
        }
    }

    static func == (lhs: OfflineAction, rhs: OfflineAction) -> Bool {
        lhs.id == rhs.id
    }
}
