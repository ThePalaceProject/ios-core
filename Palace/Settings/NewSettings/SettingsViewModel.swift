//
//  SettingsViewModel.swift
//  Palace
//
//  Created for settings business logic and testability.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import SwiftUI

/// ViewModel for app-level settings management.
///
/// This ViewModel wraps `TPPSettingsProviding` to enable:
/// - Observable settings state for SwiftUI views
/// - Dependency injection for unit testing
/// - Centralized settings validation and business logic
///
/// Usage:
/// ```swift
/// // Production
/// let viewModel = SettingsViewModel()
///
/// // Testing
/// let mockSettings = TPPSettingsMock()
/// let viewModel = SettingsViewModel(settings: mockSettings)
/// ```
@MainActor
final class SettingsViewModel: ObservableObject {
  
  // MARK: - Dependencies
  
  private let settings: TPPSettingsProviding
  private let accountsManager: AccountsManager
  
  // MARK: - Published Properties
  
  /// Whether beta/testing libraries are enabled.
  @Published var useBetaLibraries: Bool {
    didSet {
      guard useBetaLibraries != settings.useBetaLibraries else { return }
      settings.useBetaLibraries = useBetaLibraries
    }
  }
  
  /// Whether the age check has been presented to the user.
  @Published var userPresentedAgeCheck: Bool {
    didSet {
      guard userPresentedAgeCheck != settings.userPresentedAgeCheck else { return }
      settings.userPresentedAgeCheck = userPresentedAgeCheck
    }
  }
  
  /// Whether the user has accepted the EULA.
  @Published var userHasAcceptedEULA: Bool {
    didSet {
      guard userHasAcceptedEULA != settings.userHasAcceptedEULA else { return }
      settings.userHasAcceptedEULA = userHasAcceptedEULA
    }
  }
  
  /// Whether to manually enter LCP passphrases.
  @Published var enterLCPPassphraseManually: Bool {
    didSet {
      guard enterLCPPassphraseManually != settings.enterLCPPassphraseManually else { return }
      settings.enterLCPPassphraseManually = enterLCPPassphraseManually
    }
  }
  
  /// Custom library registry server URL.
  @Published var customLibraryRegistryServer: String? {
    didSet {
      guard customLibraryRegistryServer != settings.customLibraryRegistryServer else { return }
      settings.customLibraryRegistryServer = customLibraryRegistryServer
    }
  }
  
  /// Custom main feed URL for development/testing.
  @Published var customMainFeedURL: URL? {
    didSet {
      guard customMainFeedURL != settings.customMainFeedURL else { return }
      settings.customMainFeedURL = customMainFeedURL
    }
  }
  
  /// The current account main feed URL.
  @Published private(set) var accountMainFeedURL: URL?
  
  /// The stored app version string.
  @Published private(set) var appVersion: String?
  
  /// List of accounts configured in settings.
  @Published private(set) var settingsAccountsList: [Account] = []
  
  /// Whether developer settings should be visible.
  @Published var showDeveloperSettings: Bool = false
  
  // MARK: - Computed Properties
  
  /// Whether custom feed is currently active.
  var isUsingCustomFeed: Bool {
    customMainFeedURL != nil
  }
  
  /// Whether a custom registry server is configured.
  var isUsingCustomRegistry: Bool {
    customLibraryRegistryServer != nil && !customLibraryRegistryServer!.isEmpty
  }
  
  /// Formatted version string for display.
  var formattedAppVersion: String {
    let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Palace"
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "Unknown"
    return "\(productName) version \(version) (\(build))"
  }
  
  /// Current account count.
  var accountCount: Int {
    settingsAccountsList.count
  }
  
  // MARK: - Initialization
  
  /// Creates a SettingsViewModel with the given dependencies.
  ///
  /// - Parameters:
  ///   - settings: Settings provider (defaults to `TPPSettings.shared`).
  ///   - accountsManager: Accounts manager (defaults to `AccountsManager.shared`).
  init(
    settings: TPPSettingsProviding = TPPSettings.shared,
    accountsManager: AccountsManager = AccountsManager.shared
  ) {
    self.settings = settings
    self.accountsManager = accountsManager
    
    // Initialize from settings
    self.useBetaLibraries = settings.useBetaLibraries
    self.userPresentedAgeCheck = settings.userPresentedAgeCheck
    self.userHasAcceptedEULA = settings.userHasAcceptedEULA
    self.enterLCPPassphraseManually = settings.enterLCPPassphraseManually
    self.customLibraryRegistryServer = settings.customLibraryRegistryServer
    self.customMainFeedURL = settings.customMainFeedURL
    self.accountMainFeedURL = settings.accountMainFeedURL
    self.appVersion = settings.appVersion
    
    // Load accounts list
    refreshAccountsList()
  }
  
  // MARK: - Actions
  
  /// Refreshes all settings from the underlying settings provider.
  func refreshSettings() {
    useBetaLibraries = settings.useBetaLibraries
    userPresentedAgeCheck = settings.userPresentedAgeCheck
    userHasAcceptedEULA = settings.userHasAcceptedEULA
    enterLCPPassphraseManually = settings.enterLCPPassphraseManually
    customLibraryRegistryServer = settings.customLibraryRegistryServer
    customMainFeedURL = settings.customMainFeedURL
    accountMainFeedURL = settings.accountMainFeedURL
    appVersion = settings.appVersion
    refreshAccountsList()
  }
  
  /// Refreshes the accounts list from the accounts manager.
  func refreshAccountsList() {
    settingsAccountsList = TPPSettings.shared.settingsAccountsList
  }
  
  /// Clears the custom feed URL, reverting to the default feed.
  func clearCustomFeedURL() {
    customMainFeedURL = nil
  }
  
  /// Clears the custom registry server, reverting to the default registry.
  func clearCustomRegistryServer() {
    customLibraryRegistryServer = nil
  }
  
  /// Sets a custom feed URL after validation.
  ///
  /// - Parameter urlString: The URL string to set.
  /// - Returns: `true` if the URL was valid and set, `false` otherwise.
  @discardableResult
  func setCustomFeedURL(_ urlString: String?) -> Bool {
    guard let urlString = urlString, !urlString.isEmpty else {
      customMainFeedURL = nil
      return true
    }
    
    guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
      return false
    }
    
    customMainFeedURL = url
    return true
  }
  
  /// Sets a custom registry server URL after validation.
  ///
  /// - Parameter urlString: The URL string to set.
  /// - Returns: `true` if the URL was valid and set, `false` otherwise.
  @discardableResult
  func setCustomRegistryServer(_ urlString: String?) -> Bool {
    guard let urlString = urlString, !urlString.isEmpty else {
      customLibraryRegistryServer = nil
      return true
    }
    
    // Basic validation - must be a valid URL
    guard URL(string: urlString) != nil else {
      return false
    }
    
    customLibraryRegistryServer = urlString
    return true
  }
  
  /// Marks the EULA as accepted.
  func acceptEULA() {
    userHasAcceptedEULA = true
  }
  
  /// Marks the age check as presented.
  func markAgeCheckPresented() {
    userPresentedAgeCheck = true
  }
  
  /// Toggles beta libraries setting.
  func toggleBetaLibraries() {
    useBetaLibraries.toggle()
  }
  
  /// Toggles LCP passphrase manual entry setting.
  func toggleLCPManualPassphrase() {
    enterLCPPassphraseManually.toggle()
  }
  
  /// Updates the stored app version.
  ///
  /// - Parameter version: The version string to store.
  func updateAppVersion(_ version: String) {
    settings.appVersion = version
    appVersion = version
  }
  
  /// Resets all settings to their default values.
  func resetToDefaults() {
    settings.useBetaLibraries = false
    settings.enterLCPPassphraseManually = false
    settings.customMainFeedURL = nil
    settings.customLibraryRegistryServer = nil
    
    // Refresh local state
    refreshSettings()
  }
}
