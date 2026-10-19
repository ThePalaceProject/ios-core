//
//  AudiobookRecoveryAttempts.swift
//  Palace
//
//  Per-book bounds on the automatic playback recoveries. Each recovery runs at
//  most once per patron-initiated open, so a book that keeps failing reaches
//  the patron-facing error instead of looping.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

struct AudiobookRecoveryAttempts {

    /// Where the OverDrive re-fulfilment (PP-4800) stands for one book.
    enum OverdriveRefulfill: Equatable {
        /// Not attempted since the patron last opened the book.
        case available
        /// Running: the download centre is fetching a fresh manifest. Further
        /// failures from the old player are follow-on failures.
        case inFlight
        /// Attempted. Another expired-link failure means the fresh link did not
        /// work either.
        case spent
    }

    private var overdrive: [String: OverdriveRefulfill] = [:]
    private var bearerTokenRefulfilled = Set<String>()
    private var coldLoadReopened = Set<String>()

    /// True only for an open the patron started. Every automatic re-open
    /// passes one of these flags; if such a re-open re-armed the bounds, a
    /// book that fails again after recovering would recover again, without
    /// end. PP-5241's media-services-reset episode uses the same rule.
    static func isPatronOpen(forceRefulfill: Bool, isColdLoadRecovery: Bool, isRecoveryReopen: Bool) -> Bool {
        !forceRefulfill && !isColdLoadRecovery && !isRecoveryReopen
    }

    /// Re-arms every recovery for `bookId`: a patron tapping the book again is
    /// a fresh attempt.
    mutating func notePatronOpen(of bookId: String) {
        overdrive[bookId] = nil
        bearerTokenRefulfilled.remove(bookId)
        coldLoadReopened.remove(bookId)
    }

    /// Spends the bound of the recovery that is starting. Recoveries with no
    /// bound (re-auth, the terminal outcomes) change nothing.
    mutating func recordStarted(_ recovery: AudiobookPlaybackRecovery, for bookId: String) {
        switch recovery {
        case .overdriveRefulfill:
            beginOverdriveRefulfill(for: bookId)
        case .bearerTokenRefulfill:
            recordBearerTokenRefulfill(for: bookId)
        case .coldLoadReopen, .coldLoadAwaitContentThenReopen:
            recordColdLoadReopen(for: bookId)
        case .samlReauth, .overdriveRefulfillExhausted, .terminal:
            break
        }
    }

    // MARK: OverDrive re-fulfilment

    func overdriveRefulfill(for bookId: String) -> OverdriveRefulfill {
        overdrive[bookId] ?? .available
    }

    /// available → inFlight. Any other state is left as it is.
    mutating func beginOverdriveRefulfill(for bookId: String) {
        guard overdriveRefulfill(for: bookId) == .available else { return }
        overdrive[bookId] = .inFlight
    }

    /// inFlight → spent. Any other state is left as it is.
    mutating func finishOverdriveRefulfill(for bookId: String) {
        guard overdriveRefulfill(for: bookId) == .inFlight else { return }
        overdrive[bookId] = .spent
    }

    // MARK: Bearer-token re-fulfilment

    func hasAttemptedBearerTokenRefulfill(for bookId: String) -> Bool {
        bearerTokenRefulfilled.contains(bookId)
    }

    mutating func recordBearerTokenRefulfill(for bookId: String) {
        bearerTokenRefulfilled.insert(bookId)
    }

    // MARK: Cold-load re-open

    func hasAttemptedColdLoadReopen(for bookId: String) -> Bool {
        coldLoadReopened.contains(bookId)
    }

    mutating func recordColdLoadReopen(for bookId: String) {
        coldLoadReopened.insert(bookId)
    }
}
