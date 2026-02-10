//
//  TPPSettingsProviding.swift
//  Palace
//
//  Created for dependency injection support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Protocol for accessing application settings, enabling dependency injection for testing.
///
/// This protocol extracts the testable interface from `TPPSettings`, allowing tests
/// to inject mock implementations instead of relying on the singleton that persists
/// to `UserDefaults`.
///
/// Usage in production code:
/// ```swift
/// class MyClass {
///     private let settings: TPPSettingsProviding
///
///     init(settings: TPPSettingsProviding = TPPSettings.shared) {
///         self.settings = settings
///     }
/// }
/// ```
@objc protocol TPPSettingsProviding: AnyObject {

  // MARK: - Library Feed URLs

  /// The main feed URL for the current account/library.
  /// This is the primary catalog URL used for fetching library content.
  var accountMainFeedURL: URL? { get set }

  /// Custom feed URL override. When set, this URL is used instead of
  /// the standard library feed. Set to nil to use the default feed.
  var customMainFeedURL: URL? { get set }

  // MARK: - User Preferences

  /// Whether the user wants to use beta/testing libraries in addition
  /// to production libraries.
  var useBetaLibraries: Bool { get set }

  /// Whether the age check dialog has been presented to the user.
  /// Part of COPPA compliance for children's content.
  var userPresentedAgeCheck: Bool { get set }

  /// Whether the user has accepted the End User License Agreement.
  var userHasAcceptedEULA: Bool { get set }

  // MARK: - LCP Settings

  /// Whether to prompt the user to manually enter LCP passphrases
  /// instead of attempting automatic retrieval.
  var enterLCPPassphraseManually: Bool { get set }

  // MARK: - App Metadata

  /// The stored version string of the app, used for detecting upgrades.
  var appVersion: String? { get set }

  /// Custom library registry server URL. When set, the app fetches
  /// the library list from this server instead of the default.
  var customLibraryRegistryServer: String? { get set }
}

// MARK: - TPPSettings Conformance

extension TPPSettings: TPPSettingsProviding {}
