//
//  MyBooksDownloadCenter+LCPContentFetch.swift
//  Palace
//
//  The download centre's LCP content-fetch seam: deciding whether a book that
//  holds only its `.lcpl` license still needs its `.lcpa` archive pulled, and
//  asking `LocalBookContentService` for it. Extracted from the hub rather than
//  added to it — `MyBooksDownloadCenter` is under the god-class LOC freeze, and
//  this cluster has one subject and one collaborator.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceLogging

extension MyBooksDownloadCenter {

    func redownloadLCPContentFile(for book: TPPBook) {
        localContentService.redownloadLCPContentFile(for: book)
    }

    /// PP-5135: start the background `.lcpa` fetch for an LCP audiobook that
    /// finished fulfillment holding only its `.lcpl` license.
    ///
    /// With LCP streaming ON, `LCPFulfillmentHandler` deliberately marks the book
    /// downloaded on the license alone so playback can start immediately instead
    /// of waiting on a multi-gigabyte archive. That is a good trade for START-UP
    /// latency and a bad one for the shelf's promise: the patron is told the book
    /// is Downloaded. This restores the second half — the archive also arrives,
    /// in the background, so going offline works.
    ///
    /// `lcpContentFileMissing` is the existing seam for exactly this condition
    /// (LCP-openable, content file absent); on noDRM it is always false, so this
    /// compiles and no-ops there without an `#if`.
    ///
    /// The account is passed IN rather than read here: the centre's
    /// `accountsManager` is `private`, and resolving it at the call site keeps
    /// this off `AccountsManager.shared`, which CLAUDE.md forbids in new code and
    /// which would resolve paths through the live singleton for a test centre
    /// wired to a different account.
    /// - parameter afterFailedDownload: the completion path's final verdict. Both
    ///   its arms fall through to this call, and a download can fail AFTER its
    ///   licence has landed — at which point the book still looks fetchable. PP-5148:
    ///   without this, the app starts pulling the archive for a book it has just
    ///   marked `.downloadFailed` and raised an alert for, so the patron sees an
    ///   error while gigabytes keep moving, on cellular if their settings allow.
    ///
    /// NOT defaulted, deliberately. A default turns a future caller's omission
    /// into silent pre-PP-5148 behaviour — the same shape as the bug this fixes,
    /// and no test can catch an argument nobody passed. The compiler can.
    func startLCPContentFetchIfNeeded(for book: TPPBook, account: String, afterFailedDownload: Bool) async {
        guard !afterFailedDownload else { return }
        guard lcpContentFileMissing(for: book, account: account) else { return }

        guard LocalBookContentService.backgroundFetchAllowed(
            isConnectedToNetwork: reachability.isConnectedToNetwork(),
            isOnWiFi: reachability.isOnWiFi,
            downloadOnlyOnWiFi: settings.downloadOnlyOnWiFi
        ) else {
            Log.info(#file, "PP-5135: '\(book.title)' has no .lcpa yet, but a background fetch is not allowed right now (offline, or cellular with download-only-on-WiFi set) — it will be retried on the next open")
            return
        }

        Log.info(#file, "PP-5135: fulfillment left '\(book.title)' license-only — fetching the .lcpa in the background so the book works offline")
        // PP-5146: the SAME account the guard above checked against, so the
        // licence lookup and the destination cannot re-resolve it independently.
        // In production all three reads resolve the same property, so this
        // removes a latent split rather than a shipped defect — see the note on
        // `redownloadLCPContentFile(for:account:)`.
        localContentService.redownloadLCPContentFile(for: book, account: account)
    }
}
