//  AudiobookSessionManager+CoverArt.swift
//
//  The player's cover-art load, split out of the session-manager hub: the
//  hub sits on a frozen size ceiling, and this is a self-contained concern.

import Foundation
import UIKit
import PalaceAudiobookToolkit
import PalaceBookModel

extension AudiobookSessionManager {

    /// Loads cover art into the playback model — both the low-res cached
    /// copy (synchronous) and the high-res registry copy (async). Split
    /// from `presentCoverArtAndNavigation` so the presenter-side call
    /// can be driven independently from tests without constructing a full
    /// `LoadedAudiobook` shape. `playbackModel` is optional for the same reason
    /// as in `pushSessionToPresenter`.
    func loadCoverArt(for book: TPPBook, into playbackModel: AudiobookPlaybackModel?) {
        if let lowRes = book.coverImage ?? book.thumbnailImage {
            playbackModel?.updateCoverImage(lowRes)
            updateCoverImage(lowRes)
        }
        let coverRegistry = bookCoverRegistryProvider()
        let task = Task { [weak self, weak playbackModel] in
            guard let img = await coverRegistry.playerCoverImage(for: book) else { return }
            await MainActor.run {
                playbackModel?.updateCoverImageAnimated(img)
                self?.updateCoverImage(img)
            }
        }
        if Self._isRunningUnderXCTest {
            _trackedCoverArtTasks.append(task)
        }
    }

    /// Local copy of the XCTest env gate, so production never retains the handle.
    static let _isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Test-only deterministic JOIN seam; NO wall-clock. `loadCoverArt`
    /// dispatches its decode as a Task the caller cannot reach, so a test that
    /// polls for `coverImage` on a deadline loses the race under parallel sim
    /// clones. Await the handle instead.
    func _awaitCoverArtLoadForTesting() async {
        guard Self._isRunningUnderXCTest else { return }
        let pending = _trackedCoverArtTasks
        _trackedCoverArtTasks = []
        for task in pending {
            _ = await task.value
        }
    }
}
