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

    /// A bounded wait for a book's content to land on disk, with optional
    /// progress. The open's content gate and the first-play recovery both wait
    /// through one injected value, so tests drive either without the
    /// production download centre.
    typealias ContentLandingWait = @MainActor (String, (@MainActor @Sendable (Float) -> Void)?) async -> Bool

    /// True once the LCP audiobook's content package is on disk. Both writers
    /// move the `.lcpa` into place with a rename
    /// (`BackgroundDownloadHandler.replaceBook`, `LocalBookContentService`), so
    /// a file at this path is a whole file and existence is the right question
    /// to ask here.
    ///
    /// `LCPAdapter.prepareLCPSource` asks a stricter one: it also reads the
    /// archive's end record. Not because it distrusts these writers, but
    /// because being wrong costs more there. This answers "may the patron open
    /// it", where a false negative only delays a prompt; the adapter chooses
    /// between reading on disk and streaming, and a file that is present but
    /// not whole stalls a chapter with no error rather than falling back.
    static func audiobookContentIsLocal(_ bookId: String) -> Bool {
        guard let url = AppContainer.production().downloadCenter.fileUrl(for: bookId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Awaits a freshly-borrowed audiobook's content download landing on disk by
    /// polling existence of the local package.
    ///
    /// While the download centre reports a running `.lcpa` transfer the wait has
    /// no fixed end (PP-5451): an archive of a gigabyte or more can take longer
    /// than any fixed window and still finish. It ends when that transfer ends:
    /// it completed, failed, or went quiet past
    /// `DownloadProgressReporter.contentTransferIdleTimeout`, the window the
    /// download centre already uses to declare a transfer dead. Until a
    /// transfer is seen, `timeout` bounds the wait as before.
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
        isLocal: @MainActor (String) -> Bool = { AudiobookSessionManager.audiobookContentIsLocal($0) },
        isTransferActive: @MainActor (String) -> Bool,
        downloadFraction: @MainActor (String) -> Float = {
            Float(AppContainer.production().downloadCenter.downloadProgress(for: $0))
        },
        now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        onProgress: (@MainActor @Sendable (Float) -> Void)? = nil
    ) async -> Bool {
        let deadline = now() + timeout
        var sawTransfer = false
        while sawTransfer || now() < deadline {
            if isLocal(bookId) { return true }
            if isTransferActive(bookId) {
                sawTransfer = true
            } else if sawTransfer {
                // A transfer clears its registration after the archive is moved
                // into place, so this second look sees a completed download.
                return isLocal(bookId)
            }
            if let onProgress {
                await onProgress(downloadFraction(bookId))
            }
            await sleep(pollInterval)
        }
        return isLocal(bookId)
    }

    /// The production content wait, asking `progressReporter` whether the
    /// book's `.lcpa` transfer is still running.
    static func contentLandingWait(progressReporter: DownloadProgressReporter) -> ContentLandingWait {
        { bookId, onProgress in
            await awaitAudiobookContentLocal(
                bookId,
                isTransferActive: { progressReporter.isLCPContentTransferActive(for: $0) },
                onProgress: onProgress
            )
        }
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

    /// Whether the `.lcpl` beside `contentURL` was issued before the book's
    /// current loan began and has not been checked against it (PP-5440).
    static func lcpLicenceNeedsCheck(_ book: TPPBook, contentURL: URL?) -> Bool {
        #if LCP
        guard let contentURL else { return false }
        return LCPLoanLicense.needsCheck(
            licenseAt: contentURL.deletingPathExtension().appendingPathExtension("lcpl"),
            loanStart: LCPLoanLicense.loanStart(of: book)
        )
        #else
        return false
        #endif
    }
}
