//
//  MyBooksDownloadCenter+FailureReporting.swift
//  Palace
//
//  The download-failure report, kept out of the LOC-frozen hub. It returns the
//  reporting `Task` so a test can join it instead of waiting on a deadline;
//  production callers go through `logBookDownloadFailure` and ignore it.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

/// Sendable carrier for a non-Sendable `[String: Any]` failure-metadata
/// dictionary crossing the `sending` `Task` boundary in `reportDownloadFailure`.
/// INVARIANT — the dictionary is fully assembled synchronously before the `Task`
/// is enqueued and thereafter read-only; only the single logging `Task` consumes
/// it, so `@unchecked Sendable` waives no real race. Mirrors `BorrowErrorDictBox`.
private final class DownloadFailureMetadataBox: @unchecked Sendable {
    let metadata: [String: Any]
    init(_ metadata: [String: Any]) { self.metadata = metadata }
}

extension MyBooksDownloadCenter {
    @discardableResult
    func reportDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) -> Task<Void, Never> {
        let rights = downloadInfo(forBookIdentifier: book.identifier)?.rightsManagementString ?? ""

        var dict: [String: Any] = metadata ?? [:]
        dict["book"] = book.loggableDictionary()
        dict["rightsManagement"] = rights
        dict["taskOriginalRequest"] = downloadTask.originalRequest?.loggableString
        dict["taskCurrentRequest"] = downloadTask.currentRequest?.loggableString
        dict["response"] = downloadTask.response ?? "N/A"
        dict["downloadError"] = downloadTask.error ?? "N/A"

        // Swift 6 `complete`: box the non-Sendable `[String: Any]` metadata before
        // the `sending` `Task` boundary (see `DownloadFailureMetadataBox`); `dict`
        // is fully built above and read-only thereafter.
        let metadataBox = DownloadFailureMetadataBox(dict)
        return Task { [weak self] in
            await self?.deviceSpecificErrorMonitor.logDownloadFailure(
                book: book,
                reason: reason,
                error: downloadTask.error,
                metadata: metadataBox.metadata
            )
        }
    }
}
