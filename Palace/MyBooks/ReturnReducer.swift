//
//  ReturnReducer.swift
//  Palace
//
//  E2 (WS7) pure decision core extracted from `BookReturnService`.
//
//  Per Contract E (swarm_8ce6f5ae), `BookReturnService` stays as the
//  EFFECT-RUNNER (it owns the async revoke fetch, the `setProcessing`
//  lifecycle, the `TPPAnnotations.deleteAllBookmarks` callback nesting, the
//  post-return sync, the re-auth recursion, and all alert/offline I/O). This
//  reducer owns the pure branch SELECTION that the service used to make inline:
//
//    - `startRoute`     — no-revokeURL cleanup vs. network revoke.
//    - `classifyError`  — the revoke-failure ladder (parse-fail-as-success /
//                         loan-gone / re-auth / offline-enqueue / generic).
//    - `cleanupEffects` — the ordered "treat-as-success" teardown sequence
//                         shared by the no-revokeURL, OPDS-parse-fail, and
//                         loan-gone paths (deduplicated here so all three
//                         cannot drift apart).
//
//  It references NO singletons, network, keychain, `Task`, `Date`, or
//  `#if FEATURE_*` runtime checks — DRM/offline applicability arrive as facts.
//  `[Effect]: Equatable` + enum decisions make the 100%-mutation bar reachable.
//  `ReturnReducerContractTests` interprets `cleanupEffects` into a `CallLog`
//  using the same labels `BookReturnServiceContractTests` records, proving the
//  emitted teardown is shape-equal to the E1 service snapshot.
//

import Foundation

enum ReturnReducer {

    // MARK: - Top-level route

    enum StartRoute: Equatable {
        /// `book.revokeURL == nil` — skip the OPDS round trip, clean up locally.
        case cleanupWithoutNetwork
        /// A revoke URL exists — set processing and fetch the revoke feed.
        case revokeOverNetwork
    }

    static func startRoute(hasRevokeURL: Bool) -> StartRoute {
        hasRevokeURL ? .revokeOverNetwork : .cleanupWithoutNetwork
    }

    // MARK: - Revoke-failure classification

    /// Pure facts the service extracts from a revoke failure. Kept as values so
    /// the classifier never touches an `Error`/`NSError`/problem-doc object.
    struct ErrorFacts: Equatable {
        /// `error` is `PalaceError.parsing(.opdsFeedInvalid)` — the OverDrive
        /// revoke endpoint returns non-OPDS XML that the parser rejects, but the
        /// revoke almost certainly SUCCEEDED server-side.
        let isOPDSParseFailure: Bool
        /// Problem-doc type is `TypeNoActiveLoan`.
        let isNoActiveLoan: Bool
        /// Problem-doc detail contains `DetailLoanTermLimitReached`.
        let isLoanTermLimitReached: Bool
        /// The failure is a recoverable auth error (invalid-credentials type,
        /// recoverable-auth problem doc, or the invalid-credentials NSError code).
        let isAuthError: Bool
        /// A genuine offline / no-connection `NSURLError`.
        let isOffline: Bool
        /// An offline-return enqueuer is wired (production reliability path).
        let hasOfflineEnqueuer: Bool
    }

    enum ErrorRoute: Equatable {
        /// The loan is already gone (or the revoke succeeded but returned
        /// non-OPDS XML) — run the local treat-as-success cleanup.
        case treatAsSuccessCleanup
        /// Invalid credentials — re-authenticate and retry the return.
        case reauthAndRetry
        /// Offline — enqueue for later drain; do NOT clean up locally.
        case enqueueOffline
        /// Everything else — present the return-failure alert.
        case genericFailureAlert
    }

    /// Mirrors the `handleRevokeError` ladder order: parse-fail → loan-gone →
    /// auth-error → offline → generic. Parse-fail and loan-gone collapse to the
    /// same cleanup outcome (both mean "the server no longer holds this loan").
    static func classifyError(_ facts: ErrorFacts) -> ErrorRoute {
        if facts.isOPDSParseFailure || facts.isNoActiveLoan || facts.isLoanTermLimitReached {
            return .treatAsSuccessCleanup
        }
        if facts.isAuthError {
            return .reauthAndRetry
        }
        if facts.isOffline && facts.hasOfflineEnqueuer {
            return .enqueueOffline
        }
        return .genericFailureAlert
    }

    // MARK: - Ordered cleanup sequence

    enum Effect: Equatable {
        /// `localContentService.deleteLocalContent(for:)` — only when the book
        /// had downloaded content.
        case deleteLocalContent
        /// `delegate.purgeAllAudiobookCaches(force: true)` — only when downloaded.
        case purgeAudiobookCaches
        /// `bookRegistry.setState(.unregistered, for:)`.
        case setStateUnregistered
        /// `bookRegistry.removeBook(forIdentifier:)`.
        case removeBook
        /// `bookRegistry.updateAndRemoveBook(_:)` — the NORMAL network-revoke
        /// success path (a successfully-parsed revoke feed), which supplies the
        /// returned book. Distinct from the treat-as-success cleanup that has no
        /// parsed book and uses `removeBook`.
        case updateAndRemoveBook
        /// `downloadAnnouncementService.announceReturnSucceeded(for:)`.
        case announceReturnSucceeded
    }

    /// The ordered teardown for a return that is (or is treated as) a success.
    ///
    /// - `downloaded`: gates the local-asset teardown (delete + purge).
    /// - `useUpdateAndRemove`: the normal network-success path supplies a parsed
    ///   returned book and uses `updateAndRemoveBook` THEN `setState`; the
    ///   treat-as-success cleanup paths (no parsed book) use `setState` THEN
    ///   `removeBook`. Matches `BookReturnService.swift` :364-365 vs :402-403.
    static func cleanupEffects(downloaded: Bool, useUpdateAndRemove: Bool = false) -> [Effect] {
        var effects: [Effect] = []
        if downloaded {
            effects.append(.deleteLocalContent)
            effects.append(.purgeAudiobookCaches)
        }
        if useUpdateAndRemove {
            effects.append(.updateAndRemoveBook)
            effects.append(.setStateUnregistered)
        } else {
            effects.append(.setStateUnregistered)
            effects.append(.removeBook)
        }
        effects.append(.announceReturnSucceeded)
        return effects
    }
}
