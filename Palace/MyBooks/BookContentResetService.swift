//
//  BookContentResetService.swift
//  Palace
//
//  Owns the bulk-reset flows that lived on MyBooksDownloadCenter via the
//  TPPBookDownloadsDeleting conformance: per-account content
//  obliteration (reset(account:) / reset()), audiobook deletion
//  (deleteAudiobooks(forAccount:)), and audiobook cache purging
//  (purgeAllAudiobookCaches(force:)).
//
//  Extracted so the cleanup state machine can be exercised without
//  standing up MBDC. MBDC keeps the TPPBookDownloadsDeleting
//  conformance as 1-line delegators so the
//  TPPSignInBusinessLogic.bookDownloadsCenter contract is preserved.
//

import Foundation
import PalaceLogging

/// Coordinates per-account content obliteration. Cancels in-flight
/// downloads, clears state-manager bookkeeping, removes the on-disk
/// content directory, and (for current-account paths) broadcasts a UI
/// update.
///
/// - Sendable invariant (Swift 6 `complete`-mode): every stored dependency is a
///   `let` bound at init (`bookRegistry`, `accountsManager`, `stateManager`,
///   `bookFileManager`, `progressReporter`, `localContentService`, `fileManager`)
///   and there is no mutable instance state. `reset()` hops the download-state
///   teardown into a `Task` that only touches the actor-serialized
///   `stateManager.downloadCoordinator` / `SafeDictionary` members — the same
///   already-shared services this flow drove under Swift-5 mode. `@unchecked`
///   (rather than a synthesized conformance) only because the stored service
///   types are not themselves `Sendable`; the conformance asserts the
///   immutable-dependency contract above and does not change behavior.
final class BookContentResetService: @unchecked Sendable {

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let stateManager: DownloadStateManager
    private let bookFileManager: BookFileManager
    private let progressReporter: DownloadProgressReporter
    private let localContentService: LocalBookContentService
    private let fileManager: FileManager

    init(
        bookRegistry: TPPBookRegistryProvider,
        accountsManager: AccountsManager,
        stateManager: DownloadStateManager,
        bookFileManager: BookFileManager,
        progressReporter: DownloadProgressReporter,
        localContentService: LocalBookContentService,
        fileManager: FileManager = .default
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.stateManager = stateManager
        self.bookFileManager = bookFileManager
        self.progressReporter = progressReporter
        self.localContentService = localContentService
        self.fileManager = fileManager
    }

    // MARK: - reset(account:)

    /// Resets a specific account's content. If it's the *current* account,
    /// also cancels in-flight downloads and clears state-manager
    /// bookkeeping; otherwise just deletes audiobooks + the content
    /// directory for the named account.
    func reset(account: String) {
        if accountsManager.currentAccountId == account {
            reset()
        } else {
            deleteAudiobooks(forAccount: account)
            do {
                if let url = bookFileManager.contentDirectoryURL(account) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                // Handle error, if needed
            }
        }
    }

    /// Resets the *current* account: cancels every in-flight download,
    /// clears stateManager dictionaries + the download coordinator,
    /// deletes audiobooks, removes the content directory, broadcasts a
    /// UI update.
    func reset() {
        guard let currentAccountId = accountsManager.currentAccountId else {
            return
        }

        deleteAudiobooks(forAccount: currentAccountId)

        Task { [weak self] in
            guard let self = self else { return }
            let allInfo = await self.stateManager.bookIdentifierToDownloadInfo.values()
            for info in allInfo {
                info.downloadTask.cancel(byProducingResumeData: { _ in })
            }

            await self.stateManager.bookIdentifierToDownloadInfo.removeAll()
            await self.stateManager.taskIdentifierToBook.removeAll()
            await self.stateManager.downloadCoordinator.reset()
        }

        do {
            if let url = bookFileManager.contentDirectoryURL(currentAccountId) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            // Handle error, if needed
        }

        progressReporter.broadcastUpdate()
    }

    // MARK: - deleteAudiobooks(forAccount:)

    /// Deletes local content for every audiobook in the named account's
    /// registry shard.
    func deleteAudiobooks(forAccount account: String) {
        bookRegistry.with(account: account) { registry in
            let books = registry.allBooks
            for book in books {
                if book.defaultBookContentType == .audiobook {
                    localContentService.deleteLocalContent(for: book.identifier, account: account)
                }
            }
        }
    }

    // MARK: - purgeAllAudiobookCaches(force:)

    /// Purges cached audio fragments (streaming chunks, decrypted
    /// segments) from the system Caches directory. Skipped when there
    /// are still active audiobooks in the registry, unless `force` is
    /// true (i.e. the caller is in a return / sign-out context).
    func purgeAllAudiobookCaches(force: Bool = false) {
        if !force && hasActiveAudiobooks() { return }
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let audioExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "oga", "wav"]
        if let contents = try? fileManager.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                do {
                    let rv = try url.resourceValues(forKeys: [.isDirectoryKey])
                    if rv.isDirectory == true { continue }
                    if audioExtensions.contains(url.pathExtension.lowercased()) {
                        try? fileManager.removeItem(at: url)
                    }
                } catch {
                    // ignore
                }
            }
        }
    }

    /// Returns true if the current account has any audiobooks in
    /// downloadNeeded / downloading / downloadSuccessful / used state —
    /// the proxy used by `purgeAllAudiobookCaches` to decide whether
    /// purging is safe.
    private func hasActiveAudiobooks() -> Bool {
        let matchingStates: [TPPBookState] = [.downloadNeeded, .downloading, .downloadSuccessful, .used]
        var hasActive = false
        let accountId = accountsManager.currentAccountId ?? ""
        bookRegistry.with(account: accountId) { registry in
            let audiobooks = registry.myBooks.filter { $0.defaultBookContentType == .audiobook }
            hasActive = audiobooks.contains { matchingStates.contains(registry.state(for: $0.identifier)) }
        }
        return hasActive
    }
}
