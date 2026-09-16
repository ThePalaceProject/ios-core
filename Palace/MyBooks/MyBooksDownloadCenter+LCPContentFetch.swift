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
    func startLCPContentFetchIfNeeded(for book: TPPBook, account: String) async {
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
        redownloadLCPContentFile(for: book)
    }
}
