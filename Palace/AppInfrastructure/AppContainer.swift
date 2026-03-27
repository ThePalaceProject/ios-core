//
//  AppContainer.swift
//  Palace
//
//  Composition Root for the Palace application.
//  Centralises all singleton dependencies behind protocols so that
//  any subsystem can be replaced with a test double.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The application-wide dependency container (Composition Root).
///
/// Production code should obtain dependencies through this container
/// rather than reaching for `.shared` singletons directly.
///
/// For tests, create an `AppContainer` with mock implementations:
/// ```swift
/// let container = AppContainer(
///     settings: MockSettings(),
///     bookRegistry: MockBookRegistry()
/// )
/// ```
@MainActor
final class AppContainer {

    // MARK: - Shared Instance

    static let shared = AppContainer()

    // MARK: - Dependencies

    let settings: TPPSettingsProviding
    let accounts: TPPLibraryAccountsProvider
    let userAccount: TPPUserAccountProvider
    let networkExecutor: TPPRequestExecuting
    let bookRegistry: TPPBookRegistryProvider
    let downloadCenter: MyBooksDownloadCenterProviding
    let audioSession: AudiobookSessionManaging
    let errorLogger: ErrorLogging

    // MARK: - Initialization

    /// Creates a container with the given dependencies.
    /// All parameters default to the production singletons so that
    /// production call-sites can simply use `AppContainer.shared`.
    init(
        settings: TPPSettingsProviding = TPPSettings.shared,
        accounts: TPPLibraryAccountsProvider = AccountsManager.shared,
        userAccount: TPPUserAccountProvider = TPPUserAccount.sharedAccount(),
        networkExecutor: TPPRequestExecuting = TPPNetworkExecutor.shared,
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared,
        downloadCenter: MyBooksDownloadCenterProviding = MyBooksDownloadCenter.shared,
        audioSession: AudiobookSessionManaging = AudiobookSessionManager.shared,
        errorLogger: ErrorLogging = DefaultErrorLogger()
    ) {
        self.settings = settings
        self.accounts = accounts
        self.userAccount = userAccount
        self.networkExecutor = networkExecutor
        self.bookRegistry = bookRegistry
        self.downloadCenter = downloadCenter
        self.audioSession = audioSession
        self.errorLogger = errorLogger
    }
}
