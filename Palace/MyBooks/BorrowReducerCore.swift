//
//  BorrowReducerCore.swift
//  Palace
//
//  Pure borrow decisions. `BorrowOperation` is the effect runner (network,
//  timeout, DRM activation, main-actor hops, alerts, reauth); this core decides:
//    - `responseState`: availability → registry state, plus the PP-4178
//      Loan→Hold race error.
//    - `postResponseEffects`: the ordered post-borrow success plan.
//    - `alreadyHasActiveLoan`: the SQ-007 suppression predicate.
//    - `authErrorReason` / `failureEffects`: the ordered failure-routing plan.
//  No singletons, `Task`, `Date`, network, or feature flags.
//

import Foundation
import PalaceAuth
import PalaceBookModel
import PalaceCatalog

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
            reserved: { reserved in
                state = .holding
                if !userTappedPlaceHold {
                    // Position 0 means the feed gave none.
                    error = reserved.holdPosition > 0
                        ? .holdRequeued(position: reserved.holdPosition)
                        : .bookRegistry(.holdCopyUnavailable)
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
    /// loan-class state — the auto-re-borrow simply wasn't needed.
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

    // MARK: - Phase 4: failure classification

    /// The shape of the `PalaceError` a borrow failed with, as auth routing
    /// reads it.
    enum FailureErrorCase: Equatable, Sendable {
        case authentication
        case networkUnauthorized
        case networkForbidden
        case other
    }

    /// The problem-document fields auth routing reads.
    struct FailureProblemDocument: Equatable, Sendable {
        let type: String?
        let isRecoverableAuthError: Bool
    }

    /// Why a failure counts as an auth error. `authErrorReason` returns `nil`
    /// when it does not.
    enum AuthErrorReason: Equatable, Sendable {
        case authenticationError
        case credentialsProblemType
        /// PP-3716.
        case recoverableProblemDocument
        /// PP-3716: browser sign-in with credentials gets `no-active-loan`.
        case browserNoActiveLoan
        case networkUnauthorized
        case networkForbidden
        case invalidCredentialsCode
    }

    /// Problem documents that mean the stored credentials were refused, so
    /// signing in again can fix the borrow. The Circulation Manager sends the
    /// `auth/unrecoverable/credentials/invalid` form with a 401; the other two
    /// are older spellings still in use. An expired, suspended or blocked card
    /// is not here: signing in cannot fix it, so its text is shown instead.
    static let credentialsProblemTypes: Set<String> = [
        TPPProblemDocument.TypeInvalidCredentials,
        "http://librarysimplified.org/terms/problem/invalid-credentials",
        "http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid",
    ]

    /// Classifies a borrow failure. A problem document decides on its own: one
    /// that is not about credentials (a loan limit arrives as 403 with one) is
    /// not an auth error, since signing in cannot fix it (PP-5359). Without a
    /// document, a bare 401/403 or the invalid-credentials code is one; a
    /// timeout or server error is not.
    static func authErrorReason(
        errorCase: FailureErrorCase,
        problemDocument: FailureProblemDocument?,
        isBrowserBased: Bool,
        hasCredentials: Bool,
        nsErrorCode: Int
    ) -> AuthErrorReason? {
        if errorCase == .authentication { return .authenticationError }

        if let doc = problemDocument {
            if credentialsProblemTypes.contains(doc.type ?? "") { return .credentialsProblemType }
            if doc.isRecoverableAuthError { return .recoverableProblemDocument }
            if doc.type == TPPProblemDocument.TypeNoActiveLoan, isBrowserBased, hasCredentials {
                return .browserNoActiveLoan
            }
            return nil
        }

        // An OPDS path can strip the problem document from a 401.
        if errorCase == .networkUnauthorized { return .networkUnauthorized }
        if errorCase == .networkForbidden { return .networkForbidden }
        if nsErrorCode == TPPErrorCode.invalidCredentials.rawValue { return .invalidCredentialsCode }
        return nil
    }

    // MARK: - Phase 5: failure route

    /// The account's authentication type as failure routing reads it.
    /// `.noAuthentication` covers a missing definition and the types that need
    /// no sign-in (anonymous, COPPA).
    enum FailureAuthKind: Equatable, Sendable {
        case noAuthentication
        case basic
        case token
        case saml
        case oidc
        case oauthIntermediary

        /// SAML, OIDC and OAuth-intermediary (Clever) re-authenticate in a browser.
        var isBrowserBased: Bool { self == .saml || self == .oidc || self == .oauthIntermediary }
    }

    indirect enum FailureEffect: Equatable, Sendable {
        /// SQ-007: no alert; clear processing again in case a notification set it.
        case suppressAndReclearProcessing
        /// `showBorrowError`. `includesOriginalError` passes the thrown error
        /// and its problem document, which only a non-`PalaceError` throw carries.
        case showBorrowError(includesOriginalError: Bool)
        /// Log only: the per-book breaker is already armed.
        case reauthBreakerTripped
        case markReauthAttempted
        case markCredentialsStale
        /// OIDC silent reauth. On success the borrow is retried once with the
        /// breaker still armed (PP-5359); on failure `fallback` runs.
        case oidcSilentReauth(fallback: FailureEffect)
        case coordinatorRefresh(reason: ReauthReason, authLabel: String)
        /// The sign-in sheet. Its completion retries the borrow when the
        /// account has credentials (and, if `requiresSignedIn`, is logged in).
        case presentSignInModal(authLabel: String, requiresSignedIn: Bool)
        /// Log only: an auth error this auth type has no recovery for.
        case noAutomaticRecovery
    }

    /// The ordered failure plan. The runner executes it in order, returns the
    /// book if a retry borrowed it, and otherwise rethrows the failure.
    static func failureEffects(
        authError: AuthErrorReason?,
        problemDocumentType: String?,
        registeredState: TPPBookState,
        hasCredentials: Bool,
        reauthAlreadyAttempted: Bool,
        authKind: FailureAuthKind,
        hasAuthCoordinator: Bool,
        includesOriginalError: Bool
    ) -> [FailureEffect] {
        let isAuthError = authError != nil
        let showError = FailureEffect.showBorrowError(includesOriginalError: includesOriginalError)

        // SQ-007: the auto-re-borrow can fail with a 401 for a loan that
        // exists. A loan-already-exists document is not an auth error, so it is
        // checked before the auth guard.
        let isLoanAlreadyExists = problemDocumentType == TPPProblemDocument.TypeLoanAlreadyExists
        if (isAuthError || isLoanAlreadyExists) && alreadyHasActiveLoan(state: registeredState) && hasCredentials {
            return [.suppressAndReclearProcessing]
        }

        guard isAuthError else { return [showError] }
        guard !reauthAlreadyAttempted else { return [.reauthBreakerTripped, showError] }

        var effects: [FailureEffect] = [.markReauthAttempted]
        if hasCredentials {
            effects.append(.markCredentialsStale)
        }

        if authKind.isBrowserBased && hasCredentials {
            if authKind == .oidc {
                let fallback: FailureEffect = hasAuthCoordinator
                    ? .coordinatorRefresh(reason: .oidcRefreshFailed, authLabel: "OIDC")
                    : .presentSignInModal(authLabel: "OIDC", requiresSignedIn: false)
                effects.append(.oidcSilentReauth(fallback: fallback))
            } else if hasAuthCoordinator {
                let isSaml = authKind == .saml
                effects.append(.coordinatorRefresh(
                    reason: isSaml ? .samlSessionExpired : .invalidCredentials,
                    authLabel: isSaml ? "SAML" : "OAuth-intermediary"
                ))
            } else {
                effects.append(.presentSignInModal(authLabel: "SAML", requiresSignedIn: false))
            }
        } else if hasCredentials && authKind == .basic {
            // PP-5449: the sheet offers empty fields; cancelling leaves the
            // refused barcode/PIN stored, so retry only after a real sign-in.
            effects.append(.presentSignInModal(authLabel: "Basic", requiresSignedIn: true))
        } else if !hasCredentials && authKind != .noAuthentication {
            effects.append(.presentSignInModal(authLabel: "Sign-in", requiresSignedIn: false))
        } else {
            effects.append(contentsOf: [.noAutomaticRecovery, showError])
        }
        return effects
    }
}
