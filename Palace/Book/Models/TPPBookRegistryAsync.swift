//
//  TPPBookRegistryAsync.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import UIKit
import PalaceLogging
import PalaceCatalog
import PalaceBookModel

/// Modern async/await extensions for TPPBookRegistry.
/// These provide actor-like async access to registry state, bridging
/// from the existing DispatchQueue-based synchronization.
extension TPPBookRegistry {

    // MARK: - Async State Access

    /// Async version of book(forIdentifier:)
    func bookAsync(forIdentifier identifier: String?) async -> TPPBook? {
        return await withCheckedContinuation { continuation in
            continuation.resume(returning: self.book(forIdentifier: identifier))
        }
    }

    /// Async version of state(for:)
    func stateAsync(for identifier: String?) async -> TPPBookState {
        return await withCheckedContinuation { continuation in
            continuation.resume(returning: self.state(for: identifier))
        }
    }

    // MARK: - Async Sync

    /// Asynchronously syncs the registry with the server
    /// - Returns: Tuple of (errorDocument, hasNewBooks)
    /// - Throws: PalaceError if sync fails
    ///
    /// PHASE 1 (swarm_81b5099e Bucket A): blocks on `Account.awaitReady()`
    /// before reading `loansUrl`. Pre-Phase-1 this read `currentAccount?
    /// .loansUrl` directly and threw `.accountNotFound` whenever the auth
    /// document hadn't finished loading — same systemic race as the
    /// audiobook open path. The async function already had network-fetch
    /// timeouts via `OPDSFeedService.fetchFeed`; per the ADR's single-
    /// timeout policy we do NOT wrap awaitReady() in withTimeout here.
    func syncAsync(accountsManager: AccountsManager = AppContainer.production().accountsManager) async throws -> (errorDocument: [AnyHashable: Any]?, hasNewBooks: Bool) {
        guard let currentAccount = accountsManager.currentAccount else {
            throw PalaceError.authentication(.accountNotFound)
        }

        let details: AccountDetails
        do {
            details = try await currentAccount.awaitReady()
        } catch {
            Log.warn(#file, "syncAsync: awaitReady failed for \(currentAccount.uuid): \(error)")
            throw PalaceError.authentication(.accountNotFound)
        }

        guard let loansURL = details.loansUrl else {
            throw PalaceError.authentication(.accountNotFound)
        }

        do {
            let feed = try await AppContainer.production().opdsFeedService.fetchFeed(
                from: loansURL,
                resetCache: true,
                useToken: true
            )

            // Process the feed on the main actor. `processLoansSync` returns a
            // `SendableErrorDocument` carrier so the `[AnyHashable: Any]?` value
            // can cross the `@MainActor` → nonisolated actor-hop safely; unbox
            // here on the nonisolated side to preserve the public tuple shape.
            let result = await processLoansSync(feed: feed)
            return (result.errorDocument.value, result.hasNewBooks)

        } catch let error as PalaceError {
            Log.error(#file, "Registry sync failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Processes a loans feed for sync.
    ///
    /// Returns the error document inside a `SendableErrorDocument` carrier so the
    /// non-Sendable `[AnyHashable: Any]?` can cross the `@MainActor` → nonisolated
    /// boundary back to `syncAsync` under Swift 6 `complete`. (The value is always
    /// `nil` on this path — reconciliation surfaces failures by throwing, not via
    /// an error document — but boxing keeps the crossing sound and future-proof.)
    @MainActor
    private func processLoansSync(feed: TPPOPDSFeed) async -> (errorDocument: SendableErrorDocument, hasNewBooks: Bool) {
        var changesMade = false

        // Process entries - use public API
        var newBooks: [TPPBook] = []
        for entry in feed.entries {
            guard let opdsEntry = entry as? TPPOPDSEntry,
                  let book = TPPBook(entry: opdsEntry) else {
                continue
            }
            newBooks.append(book)
        }

        // Check what changed - compare with current books
        let currentBooks = self.allBooks
        let currentIds = Set(currentBooks.map { $0.identifier })
        let newIds = Set(newBooks.map { $0.identifier })

        // Books to add/update
        for book in newBooks {
            if currentIds.contains(book.identifier) {
                // Update existing
                _ = self.updatedBookMetadata(book)
            } else {
                // Add new - derive initial state from book availability
                let initialState = TPPBookRegistryRecord.deriveInitialState(for: book)
                self.addBook(book, state: initialState)
            }
            changesMade = true
        }

        let removedIds = currentIds.subtracting(newIds)
        for identifier in removedIds {
            let state = self.state(for: identifier)
            if state == .downloadSuccessful || state == .used {
                AppContainer.production().downloadCenter.deleteLocalContent(for: identifier)
            }
            self.setState(.unregistered, for: identifier)
            self.removeBook(forIdentifier: identifier)
            changesMade = true
        }

        return (SendableErrorDocument(value: nil), changesMade)
    }

    // MARK: - Async Convenience

    /// Async wrapper for sync(). Bridges the completion-handler API to async/await.
    ///
    /// The completion's `[AnyHashable: Any]?` error document is boxed in a
    /// `SendableErrorDocument` before it crosses the `@Sendable`
    /// `withCheckedContinuation` resume boundary (Swift 6 `complete`), then
    /// unboxed on the awaiting side to preserve the public tuple shape.
    func syncWithCompletion() async -> (errorDocument: [AnyHashable: Any]?, newBooks: Bool) {
        let boxed: (errorDocument: SendableErrorDocument, newBooks: Bool) = await withCheckedContinuation { continuation in
            sync { errorDoc, newBooks in
                continuation.resume(returning: (SendableErrorDocument(value: errorDoc), newBooks))
            }
        }
        return (boxed.errorDocument.value, boxed.newBooks)
    }
}
