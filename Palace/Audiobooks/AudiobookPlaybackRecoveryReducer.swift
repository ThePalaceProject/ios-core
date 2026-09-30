//
//  AudiobookPlaybackRecoveryReducer.swift
//  Palace
//
//  Decides, for one toolkit `.playbackFailed`, what state the session publishes
//  and which recovery runs. The precedence between the recovery predicates is the
//  consequential part (an expired OverDrive URL on a cold load matches two arms),
//  so it lives here as a pure, table-testable function. The published state
//  depends on the whole context, not on the selected recovery case, so `decide`
//  returns both together.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceCatalog

// MARK: - AudiobookPlaybackRecovery

/// The recovery that runs for one `.playbackFailed` signal, after the session
/// has published its state. Suppression is not a case here; it is
/// `AudiobookPlaybackOutcome.suppressFollowOnFailure`.
enum AudiobookPlaybackRecovery: Equatable {
    /// Auth-required signal on a SAML account with credentials — dispatch a
    /// credential refresh and re-open on success (PP-3703).
    case samlReauth

    /// OverDrive signed-URL expiry — re-fulfill through the download centre and
    /// re-open (PP-4800).
    case overdriveRefulfill

    /// Bearer-token vendor entitlement expiry — re-open with `forceRefulfill`
    /// to fetch a fresh manifest (HelpSpot #18471).
    case bearerTokenRefulfill

    /// Cold-load failure while the content package is still downloading: park
    /// the book, await the content landing, then re-open from the local path.
    case coldLoadAwaitContentThenReopen

    /// Cold-load failure with the content already on disk: one silent re-open.
    case coldLoadReopen

    /// No recovery applies. `dismissAndAlert` is true for a cold load that
    /// failed past its one silent re-open (dismiss the player and alert); false
    /// after playback had started (publish the error only).
    case terminal(dismissAndAlert: Bool)
}

// MARK: - AudiobookPlaybackOutcome

/// What the session does with one `.playbackFailed` signal.
enum AudiobookPlaybackOutcome: Equatable {
    /// The session is already waiting on this book's content download, so this is
    /// a follow-on failure from the streaming player and is swallowed (PP-4542).
    /// The book is already held in `.loading` by the arm that started the wait.
    case suppressFollowOnFailure

    /// Publish `.loading` (when `keepsPlayerLoading`) or `.error`, then run
    /// `recovery`. Holding `.loading` while a recovery is in flight avoids the
    /// error-then-recover flicker (PP-4800); an `.error` also makes
    /// `AudiobookSessionPresenter` call `clearActiveSession()`.
    case publish(keepsPlayerLoading: Bool, recovery: AudiobookPlaybackRecovery)
}

// MARK: - AudiobookPlaybackFailureContext

/// Every input the decision reads. `contentIsLocal` is a closure so the
/// filesystem is only consulted inside the cold-load arm.
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

/// Pure decision plus the failure-classification predicates it reads.
/// `@MainActor` matches the isolation these members had inside
/// `AudiobookSessionManager`; the logic itself reads no shared state.
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

    /// Whether the session publishes `.loading`, evaluated over the whole context
    /// independently of which recovery arm is selected.
    ///
    /// Known gap: there is no bearer-token term, so a bearer-token entitlement
    /// expiry that matches no other term publishes `.error` before re-opening,
    /// which tears down and rebuilds the view-facing session. Adding
    /// `|| shouldTriggerBearerTokenRefulfillForPlaybackFailure(…)` fixes it;
    /// `testPublishedState_bearerTokenMidListen_publishesError` pins the current
    /// behavior.
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
        // `shouldAutoReopenOnColdLoadFailure` lives on `AudiobookSessionManager`;
        // this dependency must move before the reducer can leave the app target.
        expected = expected || AudiobookSessionManager.shouldAutoReopenOnColdLoadFailure(
            hasEverStartedPlayback: context.hasEverStartedPlayback,
            hasCurrentBook: context.book != nil,
            alreadyAttempted: context.coldLoadReopenAlreadyAttempted
        )
        return expected
    }

    /// Selects the one recovery that applies, in precedence order: SAML re-auth,
    /// OverDrive re-fulfill, bearer-token re-fulfill, cold-load re-open, terminal.
    ///
    /// The order matters where arms overlap. An OverDrive title failing its first
    /// play matches both OverDrive re-fulfill and cold-load re-open; re-fulfill
    /// wins because re-opening the same stale signed URL fails identically. A
    /// SAML 401 on a cold load takes re-auth because a re-open would hit the
    /// same 401.
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

    // MARK: - Failure classification

    /// HelpSpot 17727: true when an audiobook load failed while the account is
    /// `.credentialsStale`, SAML, has credentials, and there is a book to re-open.
    /// Load-path counterpart to `shouldTriggerSAMLReauthForPlaybackFailure`.
    ///
    /// Reads the latched `.credentialsStale` state (set by the network layer on a
    /// 401) because most `AudiobookLoadError` cases carry no HTTP status.
    /// Cancellation never triggers re-auth: a superseded open should not prompt
    /// a sign-in.
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
    /// PP-4800: OverDrive audiobooks stream from time-limited signed URLs in the
    /// on-disk manifest. Returns true when the failure is a signed-URL expiry a
    /// fresh re-fulfill can fix: an OverDrive book, a 410 / resource-unavailable
    /// signal, and no prior re-fulfill this session.
    ///
    /// Conservative: 401 and loan revocation are handled elsewhere; 403 is
    /// excluded because it is ambiguous between expiry and entitlement denial;
    /// an error with no recognizable signal is not retried.
    static func shouldTriggerOverdriveRefulfillForPlaybackFailure(
        error: Error?,
        book: TPPBook?,
        alreadyAttempted: Bool
    ) -> Bool {
        guard !alreadyAttempted, let book else { return false }
        guard book.distributor?.lowercased() == OverdriveDistributorKey.lowercased() else { return false }
        // AVFoundation reports a 410 on a track fetch as NSURLErrorDomain -1008
        // with no HTTP status, so -1008 is treated as the same expiry. Offline
        // (-1009) and timeout (-1001) are not matched.
        if httpStatusCode(from: error) == 410 { return true }
        return isResourceUnavailable(from: error)
    }

#endif

    // Outside `#if FEATURE_OVERDRIVE`: `isExpiredEntitlementSignal` also uses it
    // and must compile in the noDRM build.
    /// True iff `error` carries an `NSURLErrorResourceUnavailable` (-1008) signal,
    /// at the top level, in the flattened `underlyingDomain`/`underlyingCode`
    /// userInfo scalars, or one level down the `NSUnderlyingError` chain.
    /// -1009 (offline) and -1001 (timeout) are not matched; re-fulfilling into
    /// those would fail again.
    static func isResourceUnavailable(from error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        func matches(domain: String, code: Int) -> Bool {
            domain == NSURLErrorDomain && code == NSURLErrorResourceUnavailable
        }
        if matches(domain: nsError.domain, code: nsError.code) { return true }
        // Defensive: covers a caller passing the flattened record built by
        // `buildPlaybackFailureRecord` rather than the raw error.
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

    /// Extracts the `userInfo["httpStatusCode"]` the toolkit stamps on
    /// download/streaming failures, checking one level of `NSUnderlyingError`.
    /// Outside `#if FEATURE_OVERDRIVE` so the bearer-token recovery can use it
    /// in every build.
    static func httpStatusCode(from error: Error?) -> Int? {
        guard let nsError = error as NSError? else { return nil }
        if let status = nsError.userInfo["httpStatusCode"] as? Int { return status }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let status = underlying.userInfo["httpStatusCode"] as? Int {
            return status
        }
        return nil
    }

    // MARK: - Mid-listen expired-entitlement recovery (HelpSpot #18471)

    /// True for an expired-entitlement signal a re-fulfill can recover: HTTP 410
    /// or 403, or URLError -1008. 403 is accepted here (unlike the OverDrive
    /// predicate) because the bearer-token recovery is non-destructive.
    static func isExpiredEntitlementSignal(_ error: Error?) -> Bool {
        if let status = httpStatusCode(from: error), status == 410 || status == 403 {
            return true
        }
        return isResourceUnavailable(from: error)
    }

    /// HelpSpot #18471: mid-listen expired-entitlement recovery for bearer-token
    /// audiobooks (BiblioBoard, Unlimited Listens, and other
    /// `ContentTypeBearerToken` acquisitions) whose signed content URL expires.
    ///
    /// Re-opens with `AudiobookLoader(forceRefulfill: true)`, which re-fetches the
    /// manifest from the existing fulfillment link without re-borrowing, so a
    /// revoked loan just fails again and reaches the terminal alert. That is why
    /// 403 is accepted here. OverDrive, LCP (license expiry, which a re-fetch
    /// cannot fix) and Findaway use other acquisition types and never match.
    ///
    /// Not gated on `hasEverStartedPlayback`; bounded to one attempt per book per
    /// session by `alreadyAttempted` so a persistent failure does not loop.
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
