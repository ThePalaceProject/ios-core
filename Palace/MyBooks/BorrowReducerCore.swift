//
//  BorrowReducerCore.swift
//  Palace
//
//  E2 (WS7) pure decision core extracted from `BorrowOperation`.
//
//  Per Contract E (swarm_8ce6f5ae), `BorrowOperation` stays as the
//  EFFECT-RUNNER (it owns `fetchBook`, the 30s `withTimeout`, DRM
//  `ensureDeviceActivated`, the `MainActor.run` hops, alert/modal presentation,
//  the async re-auth orchestration, and error logging). This core owns the pure
//  decisions the operation used to make inline:
//
//    - `responseState`        — availability → registry state + the PP-4178
//                               Loan→Hold race error (the home for the logic
//                               that `BorrowOperation.borrowResponseState` and
//                               `MyBooksDownloadCenter` now delegate to).
//    - `postResponseEffects`  — the ordered post-borrow success plan: the
//                               PP-4178 race throw, the app-rating note, the
//                               F-014 auto-download gate, and the hold-position
//                               sync.
//    - `alreadyHasActiveLoan` — the SQ-007 suppression predicate (an active-loan
//                               registry state means a 401 on auto-re-borrow is
//                               benign, not a credentials problem).
//
//  It references NO singletons, `Task`, `Date`, network, or `#if FEATURE_*`
//  runtime checks. `[Effect]: Equatable` + the pure predicates make the
//  100%-mutation bar reachable, and `BorrowReducerCoreContractTests` interprets
//  `postResponseEffects` into a `CallLog` using the same seam labels the
//  `BorrowOperationContractTests` record — shape-equal to the E1 service
//  snapshot (the behavior-preservation proof Contract E requires).
//

import Foundation

enum BorrowReducerCore {

    // MARK: - Phase 1: availability → state (+ Loan→Hold race)

    /// Maps a book returned from a Borrow / Place-Hold request to the resulting
    /// registry state and any error to surface. `preBorrowBook` disambiguates a
    /// deliberate Place Hold (an `unavailable`/`reserved` response is the
    /// expected queue placement, NOT a failure) from a CM Loan→Hold race where
    /// a Borrow was downgraded to a hold (PP-4178). When `preBorrowBook` is nil,
    /// retains the original behavior (treat `unavailable`/`reserved` as a race).
    static func responseState(
        for postBorrowBook: TPPBook,
        preBorrowBook: TPPBook? = nil
    ) -> (state: TPPBookState, error: PalaceError?) {
        guard let availability = postBorrowBook.defaultAcquisition?.availability else {
            return (.downloadNeeded, nil)
        }

        let userTappedPlaceHold = preBorrowBook.map(preBorrowWasUnavailable) ?? false

        var state: TPPBookState = .downloadNeeded
        var error: PalaceError?

        availability.match(
            unavailable: { _ in
                state = .holding
                if !userTappedPlaceHold {
                    error = .bookRegistry(.holdCopyUnavailable)
                }
            },
            limited: { _ in state = .downloadNeeded },
            unlimited: { _ in state = .downloadNeeded },
            reserved: { _ in
                state = .holding
                if !userTappedPlaceHold {
                    error = .bookRegistry(.holdCopyUnavailable)
                }
            },
            ready: { _ in state = .downloadNeeded }
        )

        return (state, error)
    }

    /// Pre-borrow availability discriminator: was the user looking at a
    /// no-copies title and able only to Place Hold? PP-4178 follow-up.
    private static func preBorrowWasUnavailable(_ book: TPPBook) -> Bool {
        guard let availability = book.defaultAcquisition?.availability else {
            return false
        }
        var wasUnavailable = false
        availability.match(
            unavailable: { _ in wasUnavailable = true },
            limited: { _ in },
            unlimited: { _ in },
            reserved: { _ in },
            ready: { _ in }
        )
        return wasUnavailable
    }

    // MARK: - Phase 2: post-response effect plan

    enum Effect: Equatable {
        /// PP-4178 race: the registry has already been updated to `.holding`;
        /// the operation must now throw the race error (which the catch block
        /// surfaces as a borrow-failed alert). No announce / note / download.
        case failWithRaceError
        /// `downloadAnnouncementService.announceBorrowSucceeded(for:)`.
        case announceBorrowSucceeded
        /// The app-rating secondary trigger (PP-4088) via the injected seam.
        case noteBorrowSucceeded
        /// F-014 auto-download: `attemptDownload && state == .downloadNeeded &&
        /// !isStreamingHTML`. The borrow→download chain is one user-intent step.
        case startDownload
        /// `state == .holding` → sync shortly after so the hold position updates.
        case scheduleHoldPositionSync
    }

    /// The ordered post-borrow success plan. On a Loan→Hold race the only effect
    /// is the throw; otherwise announce + rating-note, then the F-014 download
    /// gate OR the hold-position sync (mutually exclusive on state).
    static func postResponseEffects(
        state: TPPBookState,
        isStreamingHTML: Bool,
        attemptDownload: Bool,
        hasRaceError: Bool
    ) -> [Effect] {
        if hasRaceError {
            return [.failWithRaceError]
        }
        var effects: [Effect] = [.announceBorrowSucceeded, .noteBorrowSucceeded]
        if attemptDownload && state == .downloadNeeded && !isStreamingHTML {
            effects.append(.startDownload)
        }
        if state == .holding {
            effects.append(.scheduleHoldPositionSync)
        }
        return effects
    }

    // MARK: - Phase 3: SQ-007 suppression

    /// SQ-007: an auth-error on borrow is suppressed (not surfaced as a
    /// credentials problem) when the book is already in the registry with a
    /// loan-class state — the auto-re-borrow simply wasn't needed. Mirrors
    /// `BorrowOperation.handleBorrowAuthErrorIfNeeded` :648-658.
    static func alreadyHasActiveLoan(state: TPPBookState) -> Bool {
        switch state {
        case .downloadNeeded, .downloading, .downloadSuccessful,
             .downloadFailed, .holding, .SAMLStarted, .used, .returning:
            return true
        case .unregistered, .unsupported:
            return false
        @unknown default:
            return false
        }
    }
}
