//
//  AudiobookSessionManager+LandedArchive.swift
//  Palace
//
//  Rebinding a streaming session once its package reaches disk.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import PalaceLogging

extension AudiobookSessionManager {

    /// Reopens the session when the package it is streaming lands on disk.
    ///
    /// A session's transport is fixed at open — `archiveIsLocalFile()` is
    /// `licenseUrl == nil` — so one opened for streaming keeps serving remote
    /// reads after the bytes are already local, and the patron waits on a
    /// stream it no longer needs. Quitting and relaunching fixes it by hand,
    /// because that builds a session bound to the file; this does the same for
    /// them.
    ///
    /// The falling edge alone is not enough: it can arrive for a cancelled or
    /// failed transfer, and it can be stale. Both are settled by asking whether
    /// the package is actually on disk.
    func subscribeToLandedArchive() {
        archiveTransferPublisher?
            .receive(on: DispatchQueue.main)
            .sink { [weak self] identifier, isActive in
                guard let self, !isActive else { return }
                self.handleLandedArchive(for: identifier)
            }
            .store(in: &lifecycleCancellables)
    }

    /// Split from the subscription so a test can drive it without a publisher.
    func handleLandedArchive(for identifier: String) {
        guard let book = currentBook, book.identifier == identifier else { return }
        guard Self.shouldReopenForLandedArchive(
            sessionIsStreaming: sessionOpenedStreaming,
            contentIsLocal: contentIsLocal(identifier),
            isPlaying: isPlaying,
            hasCurrentBook: true,
            alreadyReopened: recoveryAttempts.hasAttemptedLandedArchiveReopen(for: identifier)
        ) else { return }
        recoveryAttempts.recordLandedArchiveReopen(for: identifier)
        Log.info(#file, "LCP package landed while streaming — re-opening the session from the local file")
        Task { [weak self] in
            guard let self else { return }
            guard self.currentBook?.identifier == identifier else { return }
            _ = await self.openAudiobook(book, startPlaying: true, forceRefulfill: false)
        }
    }
}
