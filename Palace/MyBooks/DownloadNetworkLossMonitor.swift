//
//  DownloadNetworkLossMonitor.swift
//  Palace
//
//  Fails in-flight downloads when connectivity drops (PP-4114), so a download
//  does not sit on URLSession's request timeout with no alert.
//

import Combine
import Foundation
import PalaceBookModel
import PalaceBookRegistry
import PalaceUtilities

/// Watches connectivity and, on each offline transition, cancels every active
/// download task and fails the books that are still downloading.
///
/// Owned by `AppContainer`, built against the container's download center by
/// `AppContainer.makeDownloadNetworkLossMonitor(for:)`. It reads
/// the center's active-download maps and the registry, and reports failures
/// through `failDownload`; it holds no reference to the center itself.
@MainActor
final class DownloadNetworkLossMonitor {
    /// Task identifier → book, as maintained by the download center.
    private let activeTasks: SafeDictionary<Int, TPPBook>
    /// Book identifier → download info, as maintained by the download center.
    private let activeDownloads: SafeDictionary<String, MyBooksDownloadInfo>
    private let bookRegistry: TPPBookRegistryProvider
    private let failDownload: @MainActor (TPPBook, String) -> Void
    private var connectivityCancellable: AnyCancellable?

    /// The most recent failure pass. Retained so callers and tests can await
    /// the work an offline transition started instead of polling for it.
    private(set) var lastFailureTask: Task<Void, Never>?

    init(
        connectivity: AnyPublisher<Bool, Never>,
        activeTasks: SafeDictionary<Int, TPPBook>,
        activeDownloads: SafeDictionary<String, MyBooksDownloadInfo>,
        bookRegistry: TPPBookRegistryProvider,
        failDownload: @escaping @MainActor (TPPBook, String) -> Void
    ) {
        self.activeTasks = activeTasks
        self.activeDownloads = activeDownloads
        self.bookRegistry = bookRegistry
        self.failDownload = failDownload
        // `dropFirst()` skips the publisher's replay of the current value, so
        // building the monitor while online or offline triggers nothing; only
        // a later transition to offline does.
        connectivityCancellable = connectivity
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.failActiveDownloads()
                }
            }
    }

    /// Cancels every active download task and fails each book whose registry
    /// state is `.downloading` or `.SAMLStarted`. The cancelled completions
    /// that follow are filtered by `DownloadTaskLifecycleService`, so a book
    /// gets one alert.
    func failActiveDownloads() {
        lastFailureTask = Task { [weak self] in
            await self?.performFailurePass()
        }
    }

    /// Runs off the main actor, hopping to it only for the registry reads and
    /// the failure reports.
    nonisolated private func performFailurePass() async {
        // Snapshot before mutating: failing a book empties the maps
        // asynchronously.
        let activePairs = await activeTasks.allPairs()
        let activeInfos = await activeDownloads.values()
        guard !activePairs.isEmpty else { return }

        // `activeTasks` can hold stale entries for finished downloads, so only
        // books the registry still shows in flight are failed; a downloaded
        // book must not flip to `.downloadFailed` when airplane mode is on.
        let booksToFail: [TPPBook] = await MainActor.run { [weak self] in
            guard let self else { return [] }
            return activePairs.compactMap { (_, book) -> TPPBook? in
                let state = self.bookRegistry.state(for: book.identifier)
                return (state == .downloading || state == .SAMLStarted) ? book : nil
            }
        }

        // Cancel first so iOS stops driving the tasks. Cancelling a task the
        // system has already finished is a no-op.
        for info in activeInfos {
            info.downloadTask.cancel()
        }

        guard !booksToFail.isEmpty else { return }

        let message = NSLocalizedString(
            "The connection was lost during the download.",
            comment: "Body for the network-loss alert that fires when reachability drops mid-download (PP-4114)."
        )
        await MainActor.run { [weak self] in
            guard let self else { return }
            for book in booksToFail {
                self.failDownload(book, message)
            }
        }
    }
}
