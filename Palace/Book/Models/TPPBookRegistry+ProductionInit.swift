//
//  TPPBookRegistry+ProductionInit.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry

extension RegistryExternalDependencies {
    /// The production wiring for the registry engine's external collaborators —
    /// lazily resolves the live download center, OPDS feed service, sideload set,
    /// registry-directory path rule, and availability-change hook via the
    /// composition root (god-class decomposition Wave 2b). The provider closures
    /// keep the SAME deferred `AppContainer.production()` resolution the engine's
    /// former inline closures had. This is the SINGLE definition of the registry's
    /// live collaborators — both `AppContainer` and the `(accountsManager:imageLoader:)`
    /// convenience init below use it, so the two never drift.
    static func production() -> RegistryExternalDependencies {
        RegistryExternalDependencies(
            downloadService: { AppContainer.production().downloadCenter },
            loansFeedFetcher: { AppContainer.production().opdsFeedService },
            sideloadedIdentifiers: { AppContainer.production().sideloadedBookRegistry.identifiers },
            registryDirectory: { TPPBookContentMetadataFilesHelper.directory(for: $0) },
            onAvailabilityChange: { NotificationService.compareAvailability(cachedRecord: $0, andNewBook: $1) }
        )
    }
}

extension TPPBookRegistry {
    /// Convenience init around a concrete `AccountsManager` — builds the
    /// `AccountScopeProviding` adapter + the production dependency bundle.
    /// Behavior-identical to the pre-extraction `init(accountsManager:imageLoader:)`
    /// (which hard-coded these same `AppContainer.production()` closures). Used by
    /// `AppContainer._buildCachedAppContainer` and by the registry test suites that
    /// drive the facade against a fixture AccountsManager.
    convenience init(
        accountsManager: AccountsManager,
        imageLoader: ImageLoading,
        onIllegalTransition: @escaping IllegalTransitionHandler = TPPBookRegistry.defaultIllegalTransitionHandler
    ) {
        self.init(
            accountScope: AccountsManagerAccountScopeAdapter(accountsManager: accountsManager),
            imageLoader: imageLoader,
            dependencies: .production(),
            onIllegalTransition: onIllegalTransition
        )
    }
}
