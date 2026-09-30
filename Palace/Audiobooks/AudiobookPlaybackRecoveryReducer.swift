//
//  AudiobookPlaybackRecoveryReducer.swift
//  Palace
//
//  The playback-failure decision for audiobooks: given a toolkit
//  `.playbackFailed` and the session's per-book attempt bookkeeping, what the
//  session publishes and which of the five recovery paths (or none) runs.
//
//  WHY A REDUCER AND NOT FIVE PREDICATES
//
//  The five predicates below were already pure and already unit-pinned
//  individually (`AudiobookLoadFailureSAMLReauthTests`,
//  `AudiobookBearerTokenRecoveryTests`, `AudiobookColdLoadRecoveryTests`,
//  `OverdriveFulfillmentTests`, `AudiobookVendorRecoveryContractTests`). What no
//  test reached was the PRECEDENCE between them, because the ordering lived as a
//  chain of early-returning `if` arms inside `handleManagerState`, which
//  `AudiobookSessionManager.swift` itself records as unreachable from a test:
//  "nothing in PalaceTests drives `handleManagerState`."
//
//  Ordering is where the consequential failures live. Two predicates can both be
//  true for one error — an OverDrive title whose signed URL expired on a cold
//  load matches both the OverDrive arm and the cold-load arm — and which one
//  wins decides whether the patron gets fresh signed URLs or a silent re-open of
//  a dead one. `decide(_:)` makes that finite and enumerable, per CLAUDE.md's
//  "test the transition table, not scenarios."
//
//  WHY THE PUBLISHED STATE IS NOT A PROPERTY OF THE RECOVERY CASE
//
//  It cannot be, and an earlier revision of this file got that wrong. The
//  published state is a function of the CONTEXT — the shipped disjunction
//  `SAML || OverDrive || coldLoad`, evaluated whole, independently of which arm
//  the precedence chain then selects. The recovery case does not determine it.
//
//  Five of the six recoveries happen to determine it as a theorem: `.samlReauth`
//  is only selected when the SAML term is true, `.overdriveRefulfill` only when
//  the OverDrive term is true, both cold-load arms only when the cold-load term
//  is true, and `.terminal` only when all three are false. `.bearerTokenRefulfill`
//  is the one case with no such implication — it is selected on a term that is
//  not IN the disjunction, so whether the session shows the loading shell or the
//  error dialog depends on whether the cold-load term happens to be true
//  alongside it. Concretely: the same bearer-token entitlement expiry publishes
//  `.loading` on a title's FIRST play of the session and `.error` mid-listen.
//
//  So `decide(_:)` returns the published state and the recovery TOGETHER, and no
//  type here can express a per-case published state. That is deliberate: a
//  `keepsPlayerLoading` property hanging off the enum is exactly the shape that
//  silently narrowed a context-dependent value into a case-dependent one, and a
//  100% mutation kill rate was compatible with it, because the tests pinned the
//  narrowed value (see
//  `.forgeos/wall-failures/2026-09-29-collapsing-a-context-dependent-value-into-a-case-dependent-one.md`).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceCatalog

// MARK: - AudiobookPlaybackRecovery

/// The recovery that runs for one `.playbackFailed` signal, after the session
/// has published its state.
///
/// Suppression is NOT a case here — a suppressed failure publishes no state and
/// runs no recovery, which is `AudiobookPlaybackOutcome.suppressFollowOnFailure`.
/// Keeping it out of this enum leaves exactly one encoding of that fact.
enum AudiobookPlaybackRecovery: Equatable {
    /// Auth-required signal on a SAML account with credentials — dispatch a
    /// credential refresh and re-open on success (PP-3703).
    case samlReauth

    /// OverDrive signed-URL expiry — re-fulfill through the download centre and
    /// re-open (WS-3 / PP-4800).
    case overdriveRefulfill

    /// Bearer-token vendor entitlement expiry — re-open with `forceRefulfill`
    /// to fetch a fresh manifest (323-Cause-3 / HelpSpot #18471).
    case bearerTokenRefulfill

    /// Cold-load failure while the content package is still downloading: park
    /// the book, await the content landing, then re-open from the local path.
    case coldLoadAwaitContentThenReopen

    /// Cold-load failure with the content already on disk: one silent re-open.
    case coldLoadReopen

    /// No recovery applies. `dismissAndAlert` is true when the failure was a
    /// cold load that persisted past the one silent re-open, which dismisses
    /// the player and surfaces the "not playable right now" alert; false for a
    /// failure after playback had already started, which only publishes the
    /// error.
    case terminal(dismissAndAlert: Bool)
}

// MARK: - AudiobookPlaybackOutcome

/// What the session does with one `.playbackFailed` signal.
enum AudiobookPlaybackOutcome: Equatable {
    /// The session is already parked awaiting this book's content download, so
    /// this failure is part of the streaming player's follow-on failure storm
    /// and is swallowed (PP-4542 A). No state is published and no recovery runs
    /// — the book is already held in `.loading` by the arm that started the wait.
    case suppressFollowOnFailure

    /// Publish `.loading` (when `keepsPlayerLoading`) or `.error`, then run
    /// `recovery`.
    ///
    /// `keepsPlayerLoading` and `recovery` are computed from the same context by
    /// the same call, which is what stops them disagreeing. While a recovery is
    /// in flight the player holds a `.loading` (recovering) state so the
    /// presenter shows the loading shell instead of flashing an error dialog
    /// that the recovery then immediately undoes — the error-then-recover
    /// flicker patrons saw on the OverDrive expired-URL path (PP-4800). An
    /// `.error` additionally tears the view-facing session down:
    /// `AudiobookSessionPresenter` calls `clearActiveSession()` on any `.error`.
    case publish(keepsPlayerLoading: Bool, recovery: AudiobookPlaybackRecovery)
}

// MARK: - AudiobookPlaybackFailureContext

/// Every input the decision reads, named explicitly so the decision is a pure
/// function of its arguments.
///
/// `contentIsLocal` is a closure, not a `Bool`, because the shipped code only
/// stats the filesystem inside the cold-load arm. Evaluating it eagerly for
/// every playback failure would add an `AppContainer.production()` read and a
/// `FileManager` hit to paths that never consult it.
struct AudiobookPlaybackFailureContext {
    let error: Error?
    let book: TPPBook?
    let userAccount: TPPUserAccount
    let isAwaitingContentDownload: Bool
    let overdriveRefulfillAlreadyAttempted: Bool
    let bearerTokenRefulfillAlreadyAttempted: Bool
    let coldLoadReopenAlreadyAttempted: Bool
    let hasEverStartedPlayback: Bool
    let contentIsLocal: @MainActor () -> Bool

    init(
        error: Error?,
        book: TPPBook?,
        userAccount: TPPUserAccount,
        isAwaitingContentDownload: Bool,
        overdriveRefulfillAlreadyAttempted: Bool,
        bearerTokenRefulfillAlreadyAttempted: Bool,
        coldLoadReopenAlreadyAttempted: Bool,
        hasEverStartedPlayback: Bool,
        contentIsLocal: @escaping @MainActor () -> Bool
    ) {
        self.error = error
        self.book = book
        self.userAccount = userAccount
        self.isAwaitingContentDownload = isAwaitingContentDownload
        self.overdriveRefulfillAlreadyAttempted = overdriveRefulfillAlreadyAttempted
        self.bearerTokenRefulfillAlreadyAttempted = bearerTokenRefulfillAlreadyAttempted
        self.coldLoadReopenAlreadyAttempted = coldLoadReopenAlreadyAttempted
        self.hasEverStartedPlayback = hasEverStartedPlayback
        self.contentIsLocal = contentIsLocal
    }
}

// MARK: - AudiobookPlaybackRecoveryReducer

/// Pure decision + the failure-classification predicates it reads.
///
/// `@MainActor` to match the isolation these members had inside
/// `AudiobookSessionManager` (a `@MainActor` class), so the move changes the
/// isolation of nothing. The members read no shared mutable state; the
/// annotation is conservation, not a requirement of the logic.
@MainActor
enum AudiobookPlaybackRecoveryReducer {

    /// Decides what the session publishes and which recovery runs.
    static func decide(_ context: AudiobookPlaybackFailureContext) -> AudiobookPlaybackOutcome {
        if context.isAwaitingContentDownload {
            return .suppressFollowOnFailure
        }
        return .publish(
            keepsPlayerLoading: recoveryIsExpected(context),
            recovery: selectRecovery(context)
        )
    }

    /// The published-state disjunction, whole and independent of which arm the
    /// precedence chain selects.
    ///
    /// This is the shipped `willRecover` expression
    /// (`AudiobookSessionManager.handleManagerState`, `.playbackFailed`) with
    /// nothing added and nothing removed — including the fact that it has no
    /// bearer-token term. 323-Cause-3 added the `.bearerTokenRefulfill` arm and
    /// did not add a term here, so a bearer-token entitlement expiry that
    /// matches no other term publishes `.error` and then re-opens, which tears
    /// the view-facing session down via the presenter's `clearActiveSession()`
    /// and rebuilds it. That is a defect in the shipped behaviour, reproduced
    /// here rather than changed inside a decomposition; adding
    /// `|| shouldTriggerBearerTokenRefulfillForPlaybackFailure(…)` is the fix,
    /// and `testPublishedState_bearerTokenMidListen_publishesError` is the test
    /// that flips.
    private static func recoveryIsExpected(_ context: AudiobookPlaybackFailureContext) -> Bool {
        var expected = shouldTriggerSAMLReauthForPlaybackFailure(
            error: context.error,
            userAccount: context.userAccount,
            currentBook: context.book
        )
#if FEATURE_OVERDRIVE
        expected = expected || shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: context.error,
            book: context.book,
            alreadyAttempted: context.overdriveRefulfillAlreadyAttempted
        )
#endif
        // Back-edge to the hub: `shouldAutoReopenOnColdLoadFailure` lives in
        // `AudiobookSessionManager+ContentOpenPolicy.swift`. Harmless in-target
        // (one namespace), but it is an edge this file would have to lose
        // before the cluster could move into a `PalaceAudiobookSession` package
        // per god-class-decomposition-plan.md §3a-1. Noted, not fixed here.
        expected = expected || AudiobookSessionManager.shouldAutoReopenOnColdLoadFailure(
            hasEverStartedPlayback: context.hasEverStartedPlayback,
            hasCurrentBook: context.book != nil,
            alreadyAttempted: context.coldLoadReopenAlreadyAttempted
        )
        return expected
    }

    /// Selects the one recovery that applies, in the shipped precedence order:
    /// SAML re-auth, OverDrive re-fulfill, bearer-token re-fulfill, cold-load
    /// re-open, terminal. (Follow-on suppression precedes all of these and is
    /// handled in `decide(_:)`, which returns before reaching here.)
    ///
    /// The order is load-bearing where two arms overlap. An OverDrive title
    /// failing its FIRST play matches both `.overdriveRefulfill` (410 /
    /// resource-unavailable on an OverDrive distributor) and `.coldLoadReopen`
    /// (`!hasEverStartedPlayback`); OverDrive wins, because re-opening the same
    /// stale signed URL fails identically while a re-fulfill produces a fresh
    /// one. Likewise a SAML 401 on a cold load takes the re-auth, not the
    /// re-open, because the re-open would hit the same 401.
    private static func selectRecovery(
        _ context: AudiobookPlaybackFailureContext
    ) -> AudiobookPlaybackRecovery {
        if shouldTriggerSAMLReauthForPlaybackFailure(
            error: context.error,
            userAccount: context.userAccount,
            currentBook: context.book
        ) {
            return .samlReauth
        }

#if FEATURE_OVERDRIVE
        if shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: context.error,
            book: context.book,
            alreadyAttempted: context.overdriveRefulfillAlreadyAttempted
        ) {
            return .overdriveRefulfill
        }
#endif

        if shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: context.error,
            book: context.book,
            alreadyAttempted: context.bearerTokenRefulfillAlreadyAttempted
        ) {
            return .bearerTokenRefulfill
        }

        if AudiobookSessionManager.shouldAutoReopenOnColdLoadFailure(
            hasEverStartedPlayback: context.hasEverStartedPlayback,
            hasCurrentBook: context.book != nil,
            alreadyAttempted: context.coldLoadReopenAlreadyAttempted
        ) {
            return context.contentIsLocal() ? .coldLoadReopen : .coldLoadAwaitContentThenReopen
        }

        return .terminal(dismissAndAlert: !context.hasEverStartedPlayback && context.book != nil)
    }

    // MARK: - Failure classification (moved verbatim from AudiobookSessionManager)

    /// HelpSpot 17727: Returns true when an audiobook OPEN (load) failed and the
    /// user's account is in `.credentialsStale` state (set upstream by the network
    /// layer when an authenticated request returned 401 / a recoverable auth doc),
    /// AND the account is SAML with credentials, AND there's a current book to
    /// re-open after re-auth. This is the load-path counterpart to
    /// `shouldTriggerSAMLReauthForPlaybackFailure` (PP-3703, which handles the
    /// playback-time 401 from OpenAccessPlayer).
    ///
    /// Why predicate on `authState == .credentialsStale` instead of inspecting the
    /// load error's underlying NSError: most `AudiobookLoadError` cases don't
    /// carry an HTTP-status-bearing underlying error (e.g. `manifestFetchFailed`
    /// is a bare case, no associated value). The credentials-stale signal is
    /// already propagated by `TPPNetworkResponder` / interceptors when any
    /// authenticated request returns 401, so by the time the loader returns
    /// failure we already know whether the credentials need refresh — just check
    /// the latched signal rather than try to re-derive it from a partial error.
    ///
    /// Cancellation never triggers re-auth (a superseded open shouldn't drag the
    /// user through a sign-in sheet they didn't ask for).
    static func shouldTriggerSAMLReauthForLoadFailure(
        loadError: AudiobookLoadError,
        userAccount: TPPUserAccount,
        currentBook: TPPBook?
    ) -> Bool {
        if case .cancelled = loadError {
            return false
        }
        return userAccount.authState == .credentialsStale
            && userAccount.authDefinition?.isSaml == true
            && userAccount.hasCredentials()
            && currentBook != nil
    }

    /// PP-3703: Returns true when playback failed due to bearer token refresh (e.g. 401 on CM fulfill)
    /// and the account is SAML with credentials, so we should trigger re-auth and re-open the audiobook.
    /// Extracted for unit testing to prevent regressions.
    static func shouldTriggerSAMLReauthForPlaybackFailure(error: Error?, userAccount: TPPUserAccount, currentBook: TPPBook?) -> Bool {
        let nsError = error as NSError?
        let isAuthRequired = nsError?.domain == Self.openAccessPlayerErrorDomain
            && nsError?.code == Self.openAccessPlayerErrorAuthenticationRequiredCode
        return isAuthRequired
            && userAccount.authDefinition?.isSaml == true
            && userAccount.hasCredentials()
            && currentBook != nil
    }

    private static let openAccessPlayerErrorDomain = "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer"
    private static let openAccessPlayerErrorAuthenticationRequiredCode = 5 // OpenAccessPlayerError.authenticationRequired

#if FEATURE_OVERDRIVE
    /// WS-3 (3.2.0 crash-triage `04373e48`/`d2c9e0ef`): an OverDrive audiobook
    /// streams from time-limited SIGNED URLs embedded in its on-disk manifest.
    /// When those URLs expire the toolkit surfaces a `.playbackFailed` carrying
    /// an HTTP-`410` error and — because OverDrive is not SAML — the recovery in
    /// `handleManagerState` falls through to a `.unknown` dead-end with no way to
    /// play. Returns true when the failure is a RECOVERABLE signed-URL expiry a
    /// fresh re-fulfill can fix: an OverDrive book, an HTTP-410 (Gone) signal, and
    /// no prior re-fulfill this session.
    ///
    /// Conservative by design (per "when in doubt, don't re-fulfill — a false
    /// dead-end is safer than retrying into a revoked loan"): 401/auth and
    /// loan-revoked are handled elsewhere (toolkit bearer refresh / SAML re-auth)
    /// and are NOT retried here; HTTP-403 is excluded because it is ambiguous
    /// (signed-URL expiry vs entitlement denial) absent a confirmed OverDrive
    /// expiry signature; an error with no extractable HTTP status is NOT retried.
    /// Mirrors `shouldTriggerSAMLReauthForPlaybackFailure`.
    static func shouldTriggerOverdriveRefulfillForPlaybackFailure(
        error: Error?,
        book: TPPBook?,
        alreadyAttempted: Bool
    ) -> Bool {
        guard !alreadyAttempted, let book else { return false }
        guard book.distributor?.lowercased() == OverdriveDistributorKey.lowercased() else { return false }
        // A clean HTTP 410 (Gone) is the textbook signed-URL expiry. But the toolkit
        // streams OverDrive tracks through AVFoundation, which collapses a 410 on a
        // track fetch into `NSURLErrorDomain -1008` (NSURLErrorResourceUnavailable)
        // with NO extractable httpStatusCode — so the 410-only gate never actually
        // fired in the field (device repro: Mi historia / A1QA, 2026-07-15: expired
        // `links.contentlinks` signed URLs → 410 → surfaced as -1008 → dead-ended to
        // "A Problem Has Occurred"). Treat that resource-unavailable signal as the
        // same recoverable expiry a fresh re-fulfill fixes. Still conservative: 401/
        // 403 arrive as an httpStatusCode (!= 410) and no-network (-1009) / timeout
        // (-1001) are NOT resource-unavailable, so all fall through to false.
        if httpStatusCode(from: error) == 410 { return true }
        return isResourceUnavailable(from: error)
    }

#endif

    // NOTE (forward-port): `isResourceUnavailable(from:)` is deliberately OUTSIDE
    // the `#if FEATURE_OVERDRIVE` block. It began as an OverDrive-only helper, but
    // 323-Cause-3's distributor-agnostic `isExpiredEntitlementSignal` needs the
    // same signal and must compile in the noDRM configuration. develop's richer
    // implementation is kept (it also inspects the flattened
    // `underlyingDomain`/`underlyingCode` scalars) and the hotfix's simpler
    // `isResourceUnavailable(_:)` was folded into it — one implementation, the
    // strictly-more-thorough one.
    /// True iff `error` carries an `NSURLErrorResourceUnavailable` (-1008) signal —
    /// the AVFoundation manifestation of an expired OverDrive signed-URL 410. Checks
    /// the top-level error (the raw shape handed to `.playbackFailed`), the flattened
    /// `underlyingDomain`/`underlyingCode` userInfo scalars stamped by
    /// `buildPlaybackFailureRecord`, and one level down the `NSUnderlyingError` chain.
    /// Scoped to -1008 ONLY: -1009 (offline) and -1001 (timeout) are deliberately not
    /// matched — re-fulfilling into those would just fail again.
    static func isResourceUnavailable(from error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        func matches(domain: String, code: Int) -> Bool {
            domain == NSURLErrorDomain && code == NSURLErrorResourceUnavailable
        }
        if matches(domain: nsError.domain, code: nsError.code) { return true }
        // Defensive: the flattened `underlyingDomain`/`underlyingCode` scalars are the
        // shape `buildPlaybackFailureRecord` produces for the Crashlytics record. That
        // record is NOT the error handed to this gate at runtime (the raw error is —
        // caught by the top-level and nested-chain branches), so this branch is
        // belt-and-suspenders against a future call site that passes the built record.
        if let underlyingDomain = nsError.userInfo["underlyingDomain"] as? String,
           let underlyingCode = nsError.userInfo["underlyingCode"] as? Int,
           matches(domain: underlyingDomain, code: underlyingCode) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           matches(domain: underlying.domain, code: underlying.code) {
            return true
        }
        return false
    }

    // FORWARD-PORT: the hotfix relocated `shouldAutoReopenOnColdLoadFailure`
    // out of `#if FEATURE_OVERDRIVE` for the noDRM build. develop had already
    // made the identical move for the identical reason, so the hotfix's copy is
    // dropped here and develop's (below, with the fuller rationale) is kept —
    // one declaration, same behavior.

    /// Extracts an HTTP status code from a playback error. The toolkit's network
    /// layer stamps `userInfo["httpStatusCode"]` on download/streaming failures
    /// (`OpenAccessDownloadTask`); we also walk one level of the
    /// `NSUnderlyingError` chain.
    ///
    /// Relocated OUT of the `#if FEATURE_OVERDRIVE` block (323-Cause-3) so the
    /// distributor-agnostic bearer-token recovery below can reuse it in every
    /// build configuration (the OverDrive predicate above still calls it — same
    /// type, so ordering is irrelevant).
    static func httpStatusCode(from error: Error?) -> Int? {
        guard let nsError = error as NSError? else { return nil }
        if let status = nsError.userInfo["httpStatusCode"] as? Int { return status }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let status = underlying.userInfo["httpStatusCode"] as? Int {
            return status
        }
        return nil
    }

    // MARK: - 323-Cause-3 (HelpSpot #18471): mid-listen expired-entitlement recovery

    // FORWARD-PORT: the hotfix's `isResourceUnavailable(_:)` lived here. It was
    // folded into develop's `isResourceUnavailable(from:)` above — a strict
    // superset (same domain/code check plus the flattened
    // `underlyingDomain`/`underlyingCode` scalars) — so there is ONE
    // implementation rather than two near-identical helpers that could drift.

    /// True when a playback error carries an expired-entitlement signal a fresh
    /// re-fulfill can recover: an HTTP 410 (Gone) or 403 (Forbidden) surfaced by
    /// the toolkit's network layer, or a URLError -1008 (resourceUnavailable)
    /// from an expired signed URL. 403 is included here (unlike the OverDrive
    /// predicate, which excludes it) because the bearer-token recovery below is
    /// non-destructive — see `shouldTriggerBearerTokenRefulfillForPlaybackFailure`.
    static func isExpiredEntitlementSignal(_ error: Error?) -> Bool {
        if let status = httpStatusCode(from: error), status == 410 || status == 403 {
            return true
        }
        return isResourceUnavailable(from: error)
    }

    /// 323-Cause-3 (HelpSpot #18471): generalizes mid-listen expired-entitlement
    /// recovery beyond OverDrive to **bearer-token audiobooks** — the vendors
    /// (BiblioBoard, Unlimited Listens, and any other title fulfilled through an
    /// `application/vnd.librarysimplified.bearer-token+json` acquisition) whose
    /// signed content URL / entitlement expires MID-LISTEN. Before this fix such
    /// a title matched NONE of the recovery paths (SAML is 401-only, OverDrive is
    /// distributor-gated, cold-load reopen is `!hasEverStartedPlayback`-gated) and
    /// dead-ended at the "content no longer available" alert.
    ///
    /// Recovery uses the SAME proven mechanism as OverDrive: re-open via
    /// `AudiobookLoader(forceRefulfill: true)`, which drops the stale on-disk
    /// manifest and re-fetches a FRESH manifest (fresh signed URLs) from the CM
    /// through `BearerTokenAdapter`. It is **non-destructive**: it re-fetches the
    /// existing fulfillment link, it does NOT re-borrow — so a genuinely-revoked
    /// or truly-expired loan simply re-fails the fetch and falls through to the
    /// existing terminal error UX (no regression, no false loan extension). That
    /// non-destructiveness is why 403 is accepted here even though the OverDrive
    /// path conservatively excludes it: the worst case is one bounded, harmless
    /// re-fetch before the same alert the user would have seen anyway.
    ///
    /// Positive allowlist by acquisition type (`ContentTypeBearerToken`) — this
    /// is exactly the set the loader's `BearerTokenMIMEGate` claims for fresh
    /// fulfillment, so the recovery only fires where re-fetching the manifest IS
    /// the fix. Everything else is left on the existing terminal alert by
    /// construction:
    ///  - **OverDrive** carries an overdrive-profile acquisition, not
    ///    bearer-token, so it never matches here; its dedicated 410 path above
    ///    runs first and is kept byte-identical.
    ///  - **LCP / Palace Marketplace** audiobooks: a mid-listen LCP failure is
    ///    LICENSE/loan expiry, not a signed-URL expiry. The `.lcpa` is already on
    ///    disk and `redownloadLCPContentFile` skips-if-present + re-fulfills from
    ///    the stale on-disk `.lcpl`, so it CANNOT refresh an expired license. The
    ///    terminal alert is the correct outcome — left on the existing fallback.
    ///  - **Findaway / Audible** carry a distinct `ContentTypeFindaway`
    ///    acquisition (never bearer-token); their AudioEngine session re-fulfill
    ///    is not safely verifiable for a hotfix, so they too stay on the alert.
    ///
    /// NOT gated on `hasEverStartedPlayback` — that is the mid-listen exclusion
    /// this fix lifts. Bounded to one attempt per book per session by
    /// `alreadyAttempted` (mirrors the OverDrive + cold-load guards) so a
    /// persistent failure reaches the alert instead of looping. Pure, so the
    /// trigger classification is pinned by mutation testing.
    static func shouldTriggerBearerTokenRefulfillForPlaybackFailure(
        error: Error?,
        book: TPPBook?,
        alreadyAttempted: Bool
    ) -> Bool {
        guard !alreadyAttempted, let book else { return false }
        guard book.defaultAcquisition?.type == ContentTypeBearerToken else { return false }
        return isExpiredEntitlementSignal(error)
    }
}
