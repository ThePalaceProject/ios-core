//
//  AppContainer.swift
//  Palace
//
//  Dependency injection container for the Palace app.
//  Created during Phase 1 DI migration.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

// MARK: - Container Protocol

/// Protocol defining the services available from the dependency injection container.
/// This enables testing with mock containers.
protocol AppContainerProtocol {
    var bookRegistry: TPPBookRegistryProvider { get }
    var networkExecutor: TPPNetworkExecutor { get }
    var accountsManager: AccountsManager { get }
    var settings: TPPSettingsProviding { get }
}

// MARK: - Production Container

/// Production dependency injection container.
/// Created at app launch and passed through the view hierarchy.
/// All services are lazily initialized and shared within the container.
final class AppContainer: AppContainerProtocol {

    /// Shared instance for use as default parameter values.
    /// Prefer passing through SwiftUI environment or init injection.
    static let shared = AppContainer()

    // MARK: - Services

    let bookRegistry: TPPBookRegistryProvider
    let networkExecutor: TPPNetworkExecutor
    let accountsManager: AccountsManager
    let settings: TPPSettingsProviding

    // MARK: - Initialization

    /// Creates the production container using the app's real singleton instances.
    /// This is called once at app launch.
    init(
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared,
        networkExecutor: TPPNetworkExecutor = .shared,
        accountsManager: AccountsManager = .shared,
        settings: TPPSettingsProviding = TPPSettings.shared
    ) {
        self.bookRegistry = bookRegistry
        self.networkExecutor = networkExecutor
        self.accountsManager = accountsManager
        self.settings = settings
    }
}

// MARK: - SwiftUI Environment Key

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue: AppContainer = AppContainer()
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
