///
/// AppContainer.swift
/// Palace
///
/// Centralized dependency container for the Palace app.
/// Provides default singleton instances with the ability to inject
/// test doubles via protocol-typed properties.
///

import Foundation

/// A lightweight dependency container that holds references to the app's
/// core services. Every property has a production default so existing
/// call-sites continue to work unchanged. In tests, create an
/// `AppContainer` with mock implementations instead.
final class AppContainer: @unchecked Sendable {

    // MARK: - Shared Instance

    static let shared = AppContainer()

    // MARK: - Dependencies

    let settings: TPPSettingsProviding
    let accounts: TPPLibraryAccountsProvider
    let bookRegistry: TPPBookRegistryProvider
    let downloadCenter: MyBooksDownloadCenter

    // MARK: - Initialization

    init(
        settings: TPPSettingsProviding = TPPSettings.shared,
        accounts: TPPLibraryAccountsProvider = AccountsManager.shared,
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared,
        downloadCenter: MyBooksDownloadCenter = MyBooksDownloadCenter.shared
    ) {
        self.settings = settings
        self.accounts = accounts
        self.bookRegistry = bookRegistry
        self.downloadCenter = downloadCenter
    }
}
