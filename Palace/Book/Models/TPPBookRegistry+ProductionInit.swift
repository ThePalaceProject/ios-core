//
//  TPPBookRegistry+ProductionInit.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry
import PalaceFeatureFlags

extension RegistryExternalDependencies {
    /// The production wiring for the registry engine's external collaborators,
    /// resolved lazily through `AppContainer.production()`. Both `AppContainer`
    /// and the `(accountsManager:imageLoader:)` convenience init below use this
    /// single definition so the two cannot drift.
    ///
    /// - Parameter featureFlags: source of `perBookRegistryStorageEnabled`.
    ///   Without it the per-book layout stays off.
    static func production(featureFlags: FeatureFlagProviding? = nil) -> RegistryExternalDependencies {
        RegistryExternalDependencies(
            downloadService: { AppContainer.production().downloadCenter },
            loansFeedFetcher: { AppContainer.production().opdsFeedService },
            sideloadedIdentifiers: { AppContainer.production().sideloadedBookRegistry.identifiers },
            registryDirectory: { TPPBookContentMetadataFilesHelper.directory(for: $0) },
            onAvailabilityChange: { NotificationService.compareAvailability(cachedRecord: $0, andNewBook: $1) },
            perBookStorageEnabled: { featureFlags?.isFeatureEnabled(.perBookRegistryStorageEnabled) ?? false }
        )
    }
}

extension TPPBookRegistry {
    /// Convenience init around a concrete `AccountsManager` — builds the
    /// `AccountScopeProviding` adapter + the production dependency bundle.
    convenience init(
        accountsManager: AccountsManager,
        imageLoader: ImageLoading,
        featureFlags: FeatureFlagProviding? = nil,
        onIllegalTransition: @escaping IllegalTransitionHandler = TPPBookRegistry.defaultIllegalTransitionHandler
    ) {
        self.init(
            accountScope: AccountsManagerAccountScopeAdapter(accountsManager: accountsManager),
            imageLoader: imageLoader,
            dependencies: .production(featureFlags: featureFlags),
            onIllegalTransition: onIllegalTransition
        )
    }
}
