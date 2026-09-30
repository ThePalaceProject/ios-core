//
//  AudiobookSessionManager+ContentOpenPolicy.swift
//  Palace
//
//  The pure open-time policy cluster for LCP audiobooks: is the content package
//  on disk, should the open await it, should it be fetched in the background at
//  all, may a cold-load failure silently reopen once, and what a failed
//  readiness await means for a local open. Pure statics over explicit inputs,
//  kept as an extension so call sites use `AudiobookSessionManager.<name>`.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceLogging

extension AudiobookSessionManager {

    /// PP-4542: decides whether a `.playbackFailed` should trigger one silent
    /// auto-reopen before surfacing the "Audiobook Unavailable" alert.
    /// Distributor-agnostic: the cold-load race (Readium 3.9.0 rangeOutOfBounds
    /// on a not-yet-materialized LCP package) can hit any first open.
    /// - `hasEverStartedPlayback == false`: only a COLD-load failure (playback
    ///   never started this session) is a candidate; a mid-playback failure is a
    ///   different surface and must NOT silently reopen.
    /// - `hasCurrentBook`: there must be a book to reopen.
    /// - `alreadyAttempted == false`: bounded to one reopen per book per session
    ///   so a genuinely persistent failure reaches the alert instead of looping.
    ///
    /// Outside `#if FEATURE_OVERDRIVE` because its call site is unconditional
    /// and Palace-noDRM must compile.
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
    /// Only waits: `gateOnLCPContentDownload` first triggers the content
    /// download, since a license-only `.downloadSuccessful` book may have none
    /// in flight.
    /// - parameter onProgress: optional per-poll sink for the download fraction
    ///   (0…1), used to drive a determinate "Downloading…" bar.
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

    /// PP-4542: predicate for the upfront LCP content gate. With streaming off,
    /// an openable LCP audiobook whose content is not on disk must trigger a
    /// content download and await it. Cold-load re-opens skip the gate.
    static func shouldTriggerContentDownloadBeforeOpen(
        isColdLoadRecovery: Bool,
        canOpenLCPBook: Bool,
        contentIsLocal: Bool,
        streamingEnabled: Bool
    ) -> Bool {
        // PP-4957: with streaming on, an LCP audiobook plays from its license
        // alone (swift-toolkit #579), so never force a download first.
        if streamingEnabled { return false }
        return shouldFetchContentBeforeOpen(
            isColdLoadRecovery: isColdLoadRecovery,
            canOpenLCPBook: canOpenLCPBook,
            contentIsLocal: contentIsLocal
        )
    }

    /// PP-5191: what a missing registry row means for an auth verdict. A nil
    /// `currentAccount` means the registry has no row for the selected library,
    /// not that the patron is signed out; the keychain answers that
    /// (HelpSpot 19030). With no stored credentials this returns false as before.
    /// The caller must read credentials from `currentUserAccount`, never
    /// `TPPUserAccount.sharedAccount()`, so a library switch's transient nil
    /// window is covered.
    ///
    /// `nonisolated` because `CarPlayAuthHelper.isAuthenticated` calls it from a
    /// nonisolated static; the body holds no actor state.
    nonisolated static func missingRegistryRowAuthFallback(libraryID: String?, hasStoredCredentials: Bool) -> Bool {
        Log.warn(#file, "isUserAuthenticated: no registry row for \(libraryID ?? "nil") — falling back to stored credentials: hasCredentials=\(hasStoredCredentials)")
        return hasStoredCredentials
    }

    /// PP-5135: what a failed readiness await means for a local open.
    /// `awaitReady()` resolves the authentication document, which needs the
    /// network; offline it fails, and a signed-in patron holding a downloaded
    /// book must not be told to sign in. `.evicted` is excluded: it marks the
    /// previous account after a library switch, not an offline condition.
    static func offlineAuthFallback(error: Error, hasStoredCredentials: Bool) -> Bool {
        if case AccountLoadError.evicted = error { return false }
        return hasStoredCredentials
    }

    /// PP-5135: whether the open path should fetch the missing `.lcpa` at all.
    /// `shouldTriggerContentDownloadBeforeOpen` means "fetch and wait"; with
    /// streaming it returns false, but the audio still belongs on the device for
    /// offline use. Flag-independent; the caller decides whether to await.
    static func shouldFetchContentBeforeOpen(
        isColdLoadRecovery: Bool,
        canOpenLCPBook: Bool,
        contentIsLocal: Bool
    ) -> Bool {
        !isColdLoadRecovery && canOpenLCPBook && !contentIsLocal
    }
}
