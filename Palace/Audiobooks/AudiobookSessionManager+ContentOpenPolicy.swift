//
//  AudiobookSessionManager+ContentOpenPolicy.swift
//  Palace
//
//  The pure open-time policy cluster for LCP audiobooks: is the content package
//  on disk, should the open await it, should it be fetched in the background at
//  all, may a cold-load failure silently reopen once, and what a failed
//  readiness await means for a local open.
//
//  Extracted from `AudiobookSessionManager` rather than added to it. The hub is
//  under the god-class LOC freeze, and these are pure statics over explicit
//  inputs — the shape `AudiobookPositionPolicy.swift` already established for
//  audiobook decisions that want enumerating rather than scenario-testing. Kept
//  as an extension on the manager so every existing call site and test
//  (`AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen(...)`) is
//  unchanged: this is a move, not a rename.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceLogging

extension AudiobookSessionManager {

    /// PP-4542: decides whether a `.playbackFailed` should trigger ONE silent
    /// auto-reopen before surfacing the "Audiobook Unavailable" alert. Pure so
    /// the per-session bound is unit-pinned without driving the auth-gated open
    /// flow. Distributor-agnostic on purpose: the regression (Readium 3.9.0
    /// rangeOutOfBounds on a not-yet-materialized LCP package) is a cold-load
    /// race that any first-open can hit, and a reopen demonstrably recovers it.
    /// - `hasEverStartedPlayback == false`: only a COLD-load failure (playback
    ///   never started this session) is a candidate; a mid-playback failure is a
    ///   different surface and must NOT silently reopen.
    /// - `hasCurrentBook`: there must be a book to reopen.
    /// - `alreadyAttempted == false`: bounded to one reopen per book per session
    ///   so a genuinely persistent failure reaches the alert instead of looping.
    ///
    /// Lives OUTSIDE `#if FEATURE_OVERDRIVE` (unlike the sibling OverDrive
    /// helpers): the cold-load auto-recovery call site (`stopPlayback` error
    /// path) is unconditional, so gating this behind FEATURE_OVERDRIVE broke the
    /// `Palace-noDRM` target build (`type 'Self' has no member ...`). It is a
    /// pure LCP/first-open helper with no OverDrive dependency.
    static func shouldAutoReopenOnColdLoadFailure(
        hasEverStartedPlayback: Bool,
        hasCurrentBook: Bool,
        alreadyAttempted: Bool
    ) -> Bool {
        !hasEverStartedPlayback && hasCurrentBook && !alreadyAttempted
    }

    /// True once the LCP audiobook's full content package is on disk. The `.lcpa`
    /// is moved into place atomically on download completion
    /// (BackgroundDownloadHandler.replaceBook), so file existence == content
    /// complete — the same signal `LCPAdapter.prepareLCPSource` uses to prefer
    /// the reliable local path over streaming.
    static func audiobookContentIsLocal(_ bookId: String) -> Bool {
        guard let url = AppContainer.production().downloadCenter.fileUrl(for: bookId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Awaits a freshly-borrowed audiobook's content download landing on disk by
    /// polling existence of the local package. Bounded so a stalled/failed
    /// download can't hold the loading state forever; on timeout the caller
    /// surfaces the unavailable alert.
    ///
    /// 323-Cause-1: this is a *wait*, and the wait is now preceded by an
    /// explicit `lcpContentDownloadTrigger(book)` in `gateOnLCPContentDownload`
    /// — because an LCP audiobook that flipped to `.downloadSuccessful` on
    /// license-only may have NO content download in flight (content downloads
    /// separately and can permanently fail), so a poll with nothing running
    /// would spin the whole window then dead-end. The trigger makes the file
    /// actually arrive; this awaits it.
    /// - parameter onProgress: optional per-poll sink for the in-flight
    ///   download fraction (0…1), read from the download center. Lets the caller
    ///   drive a determinate "Downloading…" bar in the loading shell during the
    ///   wait instead of showing a static skeleton (fix/audiobook-first-open-hang).
    ///   MainActor-isolated to match the presenter it typically feeds.
    static func awaitAudiobookContentLocal(
        _ bookId: String,
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 0.5,
        onProgress: (@MainActor @Sendable (Float) -> Void)? = nil
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if audiobookContentIsLocal(bookId) { return true }
            if let onProgress {
                let fraction = Float(AppContainer.production().downloadCenter.downloadProgress(for: bookId))
                await onProgress(fraction)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return audiobookContentIsLocal(bookId)
    }

    /// PP-4542 / 323-Cause-1: pure predicate for the upfront LCP content gate.
    /// An LCP audiobook that is openable but whose content package isn't on
    /// disk must TRIGGER a content download and await it — it must NOT stream
    /// (broken under Readium 3.9.0) and must NOT merely poll for a file that
    /// may never land. Cold-load recovery re-opens skip the gate entirely
    /// (content is already local by then). Pure so a flipped conditional is
    /// caught by mutation testing.
    static func shouldTriggerContentDownloadBeforeOpen(
        isColdLoadRecovery: Bool,
        canOpenLCPBook: Bool,
        contentIsLocal: Bool,
        streamingEnabled: Bool
    ) -> Bool {
        // PP-4957: when streaming is ON, an LCP audiobook is playable on its
        // license alone — never force a content download before opening; let the
        // player stream via the swift-toolkit #579 fork. When OFF, the original
        // download-first gate stands: trigger iff the book is openable but its
        // `.lcpa` content is not yet on disk, and this is not a cold-load re-open
        // (whose content is already local).
        if streamingEnabled { return false }
        return shouldFetchContentBeforeOpen(
            isColdLoadRecovery: isColdLoadRecovery,
            canOpenLCPBook: canOpenLCPBook,
            contentIsLocal: contentIsLocal
        )
    }

    /// PP-5135: what a failed readiness await means for a LOCAL open.
    ///
    /// `awaitReady()` resolves the AUTHENTICATION DOCUMENT — whether a library
    /// requires auth and how. It is not the credential store, and it needs the
    /// network. Offline it cannot complete, the account parks at `.detailsFailed`,
    /// and answering "not authenticated" told a signed-in patron holding a
    /// downloaded book to sign in. Device log, airplane mode, build 505: three
    /// `Authentication Document request failed to load Code=700` then SEVEN
    /// consecutive `Validation failed: notAuthenticated` — every tap refused until
    /// a relaunch on wifi.
    ///
    /// `.evicted` is excluded because it is NOT an offline condition:
    /// `AccountsManager` writes it against the PREVIOUS account on a library
    /// switch, so treating it as offline would let a superseded library answer
    /// for a book that is not its own.
    ///
    /// Pure, and separated from the credential LOOKUP on purpose. The lookup must
    /// be scoped to the library captured before the await — `currentUserAccount`
    /// resolves through the live `currentAccountId`, which a library switch moves —
    /// and keeping that at the call site lets this decision be driven over its
    /// whole input table without a fixture.
    /// PP-5191: what a MISSING REGISTRY ROW means for an auth verdict.
    ///
    /// Sibling of `offlineAuthFallback` below, and the same distinction one step
    /// earlier. A nil `currentAccount` means the library registry has no row for the
    /// selected library — the app cannot say "which library is this, and how does it
    /// authenticate". It does NOT mean the patron is signed out: `currentAccountId` is
    /// still set and the credentials are still in the keychain, which is why HelpSpot
    /// 19030 reads "It shows that I am logged in" while this gate refused a book the
    /// patron had just borrowed.
    ///
    /// The registry answers the library question; the keychain answers the identity
    /// question. `hasStoredCredentials` needs no network and is what is actually being
    /// asked here.
    ///
    /// Monotonic: with no stored credentials this returns false exactly as before, so a
    /// genuinely signed-out patron is unaffected. The caller must source the credential
    /// read from `currentUserAccount` — never `TPPUserAccount.sharedAccount()` — so the
    /// `lastKnownCurrentUserAccount` ride-out covers the transient nil window during a
    /// library switch.
    ///
    /// Lives here rather than inline in `AudiobookSessionManager` because that hub is
    /// under the Wave 0 LOC freeze: fixes land by extracting into a collaborator, not by
    /// growing the hub.
    static func missingRegistryRowAuthFallback(libraryID: String?, hasStoredCredentials: Bool) -> Bool {
        Log.warn(#file, "isUserAuthenticated: no registry row for \(libraryID ?? "nil") — falling back to stored credentials: hasCredentials=\(hasStoredCredentials)")
        return hasStoredCredentials
    }

    static func offlineAuthFallback(error: Error, hasStoredCredentials: Bool) -> Bool {
        if case AccountLoadError.evicted = error { return false }
        return hasStoredCredentials
    }

    /// PP-5135: whether the open path should FETCH the missing `.lcpa` at all —
    /// a question the predicate above cannot answer, because it conflates two
    /// decisions that the streaming flag separates.
    ///
    /// `shouldTriggerContentDownloadBeforeOpen` means "fetch AND make the patron
    /// wait for it". Streaming's whole purpose is to remove the waiting, so it
    /// correctly returns `false` — but that also silently removed the FETCHING,
    /// and nothing else re-armed it. A borrowed LCP audiobook therefore never
    /// acquired its audio, showed as Downloaded anyway, and failed to open the
    /// moment the device went offline.
    ///
    /// Deliberately flag-independent: whether the audio belongs on the device
    /// does not depend on how quickly playback can start. The caller decides
    /// whether to await the result; this decides only whether to ask.
    static func shouldFetchContentBeforeOpen(
        isColdLoadRecovery: Bool,
        canOpenLCPBook: Bool,
        contentIsLocal: Bool
    ) -> Bool {
        !isColdLoadRecovery && canOpenLCPBook && !contentIsLocal
    }
}
