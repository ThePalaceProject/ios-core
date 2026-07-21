//
//  TPPSettingsMock.swift
//  PalaceTests
//
//  Created for dependency injection testing support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Mock implementation of `TPPSettingsProviding` for unit testing.
///
/// This mock provides stored properties that can be directly manipulated
/// in tests, avoiding UserDefaults persistence and enabling test isolation.
///
/// `@unchecked Sendable`: this mock is passed into `@MainActor` SUTs across
/// concurrency domains. ALL mutable stored state (`_accountMainFeedURL`,
/// `_customMainFeedURL`, `_useBetaLibraries`, the app-rating counters, …) is
/// guarded by a single `NSLock` via locked computed accessors, so the mock
/// honors the `Sendable` contract despite carrying real mutable state.
///
/// Usage:
/// ```swift
/// // inside an XCTestCase:
/// let mockSettings = TPPSettingsMock()
/// mockSettings.useBetaLibraries = true
/// let sut = MyClass(settings: mockSettings)
/// // Exercise behavior when beta libraries are enabled
/// ```
final class TPPSettingsMock: NSObject, TPPSettingsProviding, @unchecked Sendable {

    private let lock = NSLock()

    // MARK: - Stored Properties with Defaults

    /// The main feed URL for the current account/library.
    private var _accountMainFeedURL: URL?
    var accountMainFeedURL: URL? {
        get { lock.withLock { _accountMainFeedURL } }
        set { lock.withLock { _accountMainFeedURL = newValue } }
    }

    /// Custom feed URL override.
    private var _customMainFeedURL: URL?
    var customMainFeedURL: URL? {
        get { lock.withLock { _customMainFeedURL } }
        set { lock.withLock { _customMainFeedURL = newValue } }
    }

    /// Whether to use beta/testing libraries.
    private var _useBetaLibraries: Bool = false
    var useBetaLibraries: Bool {
        get { lock.withLock { _useBetaLibraries } }
        set { lock.withLock { _useBetaLibraries = newValue } }
    }

    /// Whether the age check has been presented.
    private var _userPresentedAgeCheck: Bool = false
    var userPresentedAgeCheck: Bool {
        get { lock.withLock { _userPresentedAgeCheck } }
        set { lock.withLock { _userPresentedAgeCheck = newValue } }
    }

    /// Whether the user has accepted the EULA.
    private var _userHasAcceptedEULA: Bool = false
    var userHasAcceptedEULA: Bool {
        get { lock.withLock { _userHasAcceptedEULA } }
        set { lock.withLock { _userHasAcceptedEULA = newValue } }
    }

    /// Whether to enter LCP passphrases manually.
    private var _enterLCPPassphraseManually: Bool = false
    var enterLCPPassphraseManually: Bool {
        get { lock.withLock { _enterLCPPassphraseManually } }
        set { lock.withLock { _enterLCPPassphraseManually = newValue } }
    }

    /// The stored app version string.
    private var _appVersion: String?
    var appVersion: String? {
        get { lock.withLock { _appVersion } }
        set { lock.withLock { _appVersion = newValue } }
    }

    /// Custom library registry server URL.
    private var _customLibraryRegistryServer: String?
    var customLibraryRegistryServer: String? {
        get { lock.withLock { _customLibraryRegistryServer } }
        set { lock.withLock { _customLibraryRegistryServer = newValue } }
    }

    /// Whether downloads are restricted to Wi-Fi only.
    private var _downloadOnlyOnWiFi: Bool = false
    var downloadOnlyOnWiFi: Bool {
        get { lock.withLock { _downloadOnlyOnWiFi } }
        set { lock.withLock { _downloadOnlyOnWiFi = newValue } }
    }

    // MARK: - App Rating (PP-4087)

    private var _appRatingSessionCount: Int = 0
    var appRatingSessionCount: Int {
        get { lock.withLock { _appRatingSessionCount } }
        set { lock.withLock { _appRatingSessionCount = newValue } }
    }

    private var _appRatingBooksCompleted: Int = 0
    var appRatingBooksCompleted: Int {
        get { lock.withLock { _appRatingBooksCompleted } }
        set { lock.withLock { _appRatingBooksCompleted = newValue } }
    }

    private var _appRatingLastPromptDate: Date?
    var appRatingLastPromptDate: Date? {
        get { lock.withLock { _appRatingLastPromptDate } }
        set { lock.withLock { _appRatingLastPromptDate = newValue } }
    }

    private var _appRatingPromptDisplayCount: Int = 0
    var appRatingPromptDisplayCount: Int {
        get { lock.withLock { _appRatingPromptDisplayCount } }
        set { lock.withLock { _appRatingPromptDisplayCount = newValue } }
    }

    private var _appRatingDismissalCount: Int = 0
    var appRatingDismissalCount: Int {
        get { lock.withLock { _appRatingDismissalCount } }
        set { lock.withLock { _appRatingDismissalCount = newValue } }
    }

    private var _appRatingOptedOut: Bool = false
    var appRatingOptedOut: Bool {
        get { lock.withLock { _appRatingOptedOut } }
        set { lock.withLock { _appRatingOptedOut = newValue } }
    }

    /// Defaults to `true` (assume crash-free), matching `TPPSettings`.
    private var _appRatingCrashFreeLastSession: Bool = true
    var appRatingCrashFreeLastSession: Bool {
        get { lock.withLock { _appRatingCrashFreeLastSession } }
        set { lock.withLock { _appRatingCrashFreeLastSession = newValue } }
    }

    // MARK: - Initialization

    override init() {
        super.init()
    }

    /// Creates a mock with pre-configured values.
    ///
    /// - Parameters:
    ///   - accountMainFeedURL: Main feed URL for the account.
    ///   - customMainFeedURL: Custom feed URL override.
    ///   - useBetaLibraries: Whether beta libraries are enabled.
    ///   - userPresentedAgeCheck: Whether age check was presented.
    ///   - userHasAcceptedEULA: Whether EULA was accepted.
    ///   - enterLCPPassphraseManually: Whether to enter LCP passphrase manually.
    ///   - appVersion: Stored app version string.
    ///   - customLibraryRegistryServer: Custom registry server URL.
    init(
        accountMainFeedURL: URL? = nil,
        customMainFeedURL: URL? = nil,
        useBetaLibraries: Bool = false,
        userPresentedAgeCheck: Bool = false,
        userHasAcceptedEULA: Bool = false,
        enterLCPPassphraseManually: Bool = false,
        appVersion: String? = nil,
        customLibraryRegistryServer: String? = nil,
        downloadOnlyOnWiFi: Bool = false
    ) {
        self._accountMainFeedURL = accountMainFeedURL
        self._customMainFeedURL = customMainFeedURL
        self._useBetaLibraries = useBetaLibraries
        self._userPresentedAgeCheck = userPresentedAgeCheck
        self._userHasAcceptedEULA = userHasAcceptedEULA
        self._enterLCPPassphraseManually = enterLCPPassphraseManually
        self._appVersion = appVersion
        self._customLibraryRegistryServer = customLibraryRegistryServer
        self._downloadOnlyOnWiFi = downloadOnlyOnWiFi
        super.init()
    }

    // MARK: - Test Helpers

    /// Resets all properties to their default values.
    ///
    /// Call this in `tearDown()` or between tests to ensure clean state:
    /// ```swift
    /// override func tearDown() {
    ///     mockSettings.reset()
    ///     super.tearDown()
    /// }
    /// ```
    func reset() {
        accountMainFeedURL = nil
        customMainFeedURL = nil
        useBetaLibraries = false
        userPresentedAgeCheck = false
        userHasAcceptedEULA = false
        enterLCPPassphraseManually = false
        appVersion = nil
        customLibraryRegistryServer = nil
        downloadOnlyOnWiFi = false
        appRatingSessionCount = 0
        appRatingBooksCompleted = 0
        appRatingLastPromptDate = nil
        appRatingPromptDisplayCount = 0
        appRatingDismissalCount = 0
        appRatingOptedOut = false
        appRatingCrashFreeLastSession = true
    }
}
