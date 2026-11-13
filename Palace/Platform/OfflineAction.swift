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

/// What running a queued action established.
enum OfflineActionOutcome: Sendable, Equatable {
    /// The server confirmed the action; it leaves the queue.
    case confirmed
    /// The server did not confirm it; the attempt counts toward `maxRetries`.
    case failed
    /// The server could not be reached; the action stays pending with its
    /// retries intact, and the drain stops until the next trigger.
    case deferred
}

/// A user-initiated action that was queued while offline.
struct OfflineAction: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let type: OfflineActionType
    let bookID: String
    let bookTitle: String
    /// The library account the action was made under. It runs only while that
    /// library is current, because the executor acts on the current library's
    /// registry and credentials. nil only in actions persisted before this
    /// field existed; `OfflineQueueService` drops those at load.
    let libraryID: String?
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
        libraryID: String,
        maxRetries: Int = 3
    ) {
        self.id = UUID()
        self.type = type
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.libraryID = libraryID
        self.createdAt = Date()
        self.state = .pending
        self.retryCount = 0
        self.maxRetries = maxRetries
    }

    /// Whether this action may run while `currentLibraryID` is the current
    /// library. An action with no library, or no current library, never may.
    func belongs(toLibrary currentLibraryID: String?) -> Bool {
        guard let libraryID, let currentLibraryID else { return false }
        return libraryID == currentLibraryID
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
