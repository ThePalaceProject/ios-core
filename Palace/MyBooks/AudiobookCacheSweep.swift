//
//  AudiobookCacheSweep.swift
//  Palace
//
//  Removes decrypted audiobook chapters from the system Caches directory.
//
//  Extracted from BookContentResetService (PP-5127) so the per-book delete
//  path can reach it too. LocalBookContentService cannot depend on
//  BookContentResetService — that service already owns a
//  LocalBookContentService, and the reverse edge would close a cycle — so the
//  sweep lives in its own type that both collaborate with instead.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry

/// Deletes cached audio fragments — streaming chunks and decrypted chapters —
/// from the app's Caches directory.
///
/// The sweep is necessarily blanket. Protected audiobooks decrypt to flat
/// files named for a hash of each track's path, and once the licence is gone
/// those paths cannot be reconstructed, so there is no way to ask "which of
/// these belong to the book being removed?". What keeps that safe is
/// `hasActiveAudiobooks`: unforced, the sweep declines to run at all while any
/// audiobook is still downloading or sitting on the shelf.
struct AudiobookCacheSweep {

    /// States that mean a book's cached chapters are still wanted. `.downloading`
    /// is included because chapters are written as they decrypt — sweeping mid
    /// download would delete work in progress underneath the player.
    private static let activeStates: [TPPBookState] = [
        .downloadNeeded, .downloading, .downloadSuccessful, .used
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "mp4", "aac", "oga", "wav"
    ]

    private let bookRegistry: TPPBookRegistryProvider
    private let fileManager: FileManager

    init(bookRegistry: TPPBookRegistryProvider, fileManager: FileManager = .default) {
        self.bookRegistry = bookRegistry
        self.fileManager = fileManager
    }

    /// - Parameters:
    ///   - force: skip the active-audiobook guard. Only the return and
    ///     sign-out flows pass `true`; they are user-initiated, infrequent, and
    ///     already tearing down content, so the cost of re-decrypting another
    ///     book later is acceptable there. The per-book delete path passes
    ///     `false` — it runs during routine shelf reconciliation, where
    ///     evicting a book the patron is listening to would be a worse defect
    ///     than the leak being fixed.
    ///   - excluding: a book that is on its way out, and so should not count
    ///     itself as a reason to keep its own chapters.
    ///
    ///     This is load-bearing rather than tidy. Of the three callers that
    ///     reach the per-book delete, only `BookRegistrySync` removes the
    ///     registry record first; `TPPBookRegistryAsync` and the expired-book
    ///     eviction in `MyBooksViewModel` both delete local content while the
    ///     departing book is still recorded as `.downloadSuccessful`. Without
    ///     this parameter the guard would see that book, call it active, and
    ///     decline — leaving the sweep a no-op on two of the three paths it
    ///     exists to fix.
    func purge(force: Bool = false, excluding excludedIdentifier: String? = nil) {
        if !force && hasActiveAudiobooks(excluding: excludedIdentifier) { return }
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cachesDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in contents {
            guard let rv = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  rv.isDirectory != true,
                  Self.audioExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Whether any audiobook on the current account still wants its chapters.
    ///
    /// Reads the injected registry directly. The alternative,
    /// `with(account: currentAccountId)`, takes a CONCRETE `TPPBookRegistry`
    /// that the real implementation builds fresh from disk — no test double can
    /// produce one, so every mock implements that method as a no-op and the
    /// block never runs. Routed that way this guard silently answered "nothing
    /// is active" in every test that reached it, which is not a guard anyone
    /// can prove. Reading the provider is also equivalent: the account asked
    /// for was always the current one, and the injected registry is that
    /// account's, carrying live state rather than a re-read of the last save.
    private func hasActiveAudiobooks(excluding excludedIdentifier: String?) -> Bool {
        bookRegistry.myBooks
            .filter { $0.defaultBookContentType == .audiobook }
            .filter { $0.identifier != excludedIdentifier }
            .contains { Self.activeStates.contains(bookRegistry.state(for: $0.identifier)) }
    }
}
