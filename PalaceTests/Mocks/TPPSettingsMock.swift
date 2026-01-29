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
/// Usage:
/// ```swift
/// func testBetaLibraries() {
///     let mockSettings = TPPSettingsMock()
///     mockSettings.useBetaLibraries = true
///
///     let sut = MyClass(settings: mockSettings)
///     // Test behavior when beta libraries are enabled
/// }
/// ```
final class TPPSettingsMock: NSObject, TPPSettingsProviding {

  // MARK: - Stored Properties with Defaults

  /// The main feed URL for the current account/library.
  var accountMainFeedURL: URL?

  /// Custom feed URL override.
  var customMainFeedURL: URL?

  /// Whether to use beta/testing libraries.
  var useBetaLibraries: Bool = false

  /// Whether the age check has been presented.
  var userPresentedAgeCheck: Bool = false

  /// Whether the user has accepted the EULA.
  var userHasAcceptedEULA: Bool = false

  /// Whether to enter LCP passphrases manually.
  var enterLCPPassphraseManually: Bool = false

  /// The stored app version string.
  var appVersion: String?

  /// Custom library registry server URL.
  var customLibraryRegistryServer: String?

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
    customLibraryRegistryServer: String? = nil
  ) {
    self.accountMainFeedURL = accountMainFeedURL
    self.customMainFeedURL = customMainFeedURL
    self.useBetaLibraries = useBetaLibraries
    self.userPresentedAgeCheck = userPresentedAgeCheck
    self.userHasAcceptedEULA = userHasAcceptedEULA
    self.enterLCPPassphraseManually = enterLCPPassphraseManually
    self.appVersion = appVersion
    self.customLibraryRegistryServer = customLibraryRegistryServer
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
  }
}
