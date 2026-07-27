//
//  BookRegistryEngineTestInits.swift
//  PalaceTests
//
//  Test-only convenience inits that let the white-box registry-engine suites keep
//  constructing `BookRegistrySync` with the pre-extraction argument shape
//  (`store:accountsManager:downloadCenterProvider:opdsFeedServiceProvider:
//  sideloadedIDsProvider:`). They map that shape onto the god-class-decomposition
//  Wave 2b `store:accountScope:dependencies:` designated init, filling the
//  registry-directory + availability-change seams with the same production values
//  the app wires — so these suites exercise byte-identical behavior through the new
//  seams without every call site rewriting the dependency bundle by hand.
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace
@testable import PalaceBookRegistry
import PalaceCatalog

extension BookRegistrySync {
    /// Pre-extraction 5-arg shape (with the sideloaded-identifiers provider).
    convenience init(
        store: BookRegistryStore,
        accountsManager: AccountsManager,
        downloadCenterProvider: @escaping @Sendable () -> MyBooksDownloadCenter,
        opdsFeedServiceProvider: @escaping @Sendable () -> any OPDSFeedFetching,
        sideloadedIDsProvider: @escaping @Sendable () -> Set<String> = { AppContainer.production().sideloadedBookRegistry.identifiers } // MIGRATED-DEFERRED: swarm_47883816 — test-engine-init DEFAULT arg mirrors the production sideloaded-IDs wiring; the closure defers resolution and callers that need isolation override it (same lazy-provider pattern as downloadCenterProvider/opdsFeedServiceProvider above)
    ) {
        self.init(
            store: store,
            accountScope: AccountsManagerAccountScopeAdapter(accountsManager: accountsManager),
            dependencies: RegistryExternalDependencies(
                downloadService: { downloadCenterProvider() },
                loansFeedFetcher: opdsFeedServiceProvider,
                sideloadedIdentifiers: sideloadedIDsProvider,
                registryDirectory: { TPPBookContentMetadataFilesHelper.directory(for: $0) },
                onAvailabilityChange: { NotificationService.compareAvailability(cachedRecord: $0, andNewBook: $1) }
            )
        )
    }
}
