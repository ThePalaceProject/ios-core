//
//  AudiobookSessionManager+ColdLoadContentWait.swift
//  Palace
//
//  Lifetime of the cold-load recovery's wait for an LCP audiobook's content
//  (PP-5451). The wait runs for as long as the download progresses, so it must
//  end when the session stops rather than outlive it.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation

extension AudiobookSessionManager {

    /// True while this session is loading `bookId`.
    func isLoading(_ bookId: String) -> Bool {
        guard currentBook?.identifier == bookId, case .loading(let loadingId) = state else { return false }
        return loadingId == bookId
    }

    /// Ends the cold-load wait and stops swallowing the waiting book's playback
    /// failures. Called by `stopPlayback`, which an open of another book also
    /// runs while this one is loading.
    func cancelColdLoadContentWait() {
        coldLoadContentWait?.cancel()
        coldLoadContentWait = nil
        awaitingContentDownloadBookIds.removeAll()
    }

    /// Called by the wait task once its wait returns. False when the wait was
    /// cancelled, whose cancel has already cleared this state. Clearing the
    /// task first keeps the re-open's own stop from cancelling the task
    /// running it.
    func endColdLoadContentWait(for bookId: String) -> Bool {
        guard !Task.isCancelled else { return false }
        coldLoadContentWait = nil
        awaitingContentDownloadBookIds.remove(bookId)
        return true
    }
}
