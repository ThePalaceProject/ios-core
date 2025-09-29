import Foundation

// MARK: - NYPLUniversalLinksSettings

@objc protocol NYPLUniversalLinksSettings: NSObjectProtocol {
  /// The URL that will be used to redirect an external authentication flow
  /// back to the our app. This URL will need to be provided to the external
  /// service. For example, Clever authentication uses this URL to redirect
  /// to the app after authenticating in Safari.
  var universalLinksURL: URL { get }
}

// MARK: - NYPLFeedURLProvider

@objc protocol NYPLFeedURLProvider {
  var accountMainFeedURL: URL? { get set }
}

// MARK: - TPPSettings

@objcMembers class TPPSettings: NSObject, NYPLFeedURLProvider, TPPAgeCheckChoiceStorage {
  static let shared = TPPSettings()

  @objc class func sharedSettings() -> TPPSettings {
    TPPSettings.shared
  }

  static let TPPAboutPalaceURLString = "http://thepalaceproject.org/"
  static let TPPUserAgreementURLString = "https://legal.palaceproject.io/End%20User%20License%20Agreement.html"
  static let TPPPrivacyPolicyURLString = "https://legal.palaceproject.io/Privacy%20Policy.html"
  static let TPPSoftwareLicensesURLString = "https://legal.palaceproject.io/software-licenses.html"

  private static let customMainFeedURLKey = "NYPLSettingsCustomMainFeedURL"
  private static let accountMainFeedURLKey = "NYPLSettingsAccountMainFeedURL"
  private static let userPresentedAgeCheckKey = "NYPLUserPresentedAgeCheckKey"
  static let userHasAcceptedEULAKey = "NYPLSettingsUserAcceptedEULA"
  private static let userSeenFirstTimeSyncMessageKey = "userSeenFirstTimeSyncMessageKey"
  private static let useBetaLibrariesKey = "NYPLUseBetaLibrariesKey"
  static let settingsLibraryAccountsKey = "NYPLSettingsLibraryAccountsKey"
  private static let versionKey = "NYPLSettingsVersionKey"
  private static let customLibraryRegistryKey = "TPPSettingsCustomLibraryRegistryKey"
  private static let enterLCPPassphraseManually = "TPPSettingsEnterLCPPassphraseManually"
  static let showDeveloperSettingsKey = "showDeveloperSettings"

  // Set to nil (the default) if no custom feed should be used.
  var customMainFeedURL: URL? {
    get {
      UserDefaults.standard.url(forKey: TPPSettings.customMainFeedURLKey)
    }
    set(customUrl) {
      if customUrl == self.customMainFeedURL {
        return
      }
      UserDefaults.standard.set(customUrl, forKey: TPPSettings.customMainFeedURLKey)
      NotificationCenter.default.post(name: Notification.Name.TPPSettingsDidChange, object: self)
    }
  }

  var accountMainFeedURL: URL? {
    get {
      UserDefaults.standard.url(forKey: TPPSettings.accountMainFeedURLKey)
    }
    set(mainFeedUrl) {
      if mainFeedUrl == self.accountMainFeedURL {
        return
      }
      UserDefaults.standard.set(mainFeedUrl, forKey: TPPSettings.accountMainFeedURLKey)
      NotificationCenter.default.post(name: Notification.Name.TPPSettingsDidChange, object: self)
    }
  }

  /// Whether the user has seen the welcome screen or completed tutorial
  var userHasSeenWelcomeScreen: Bool {
    get {
      UserDefaults.standard.bool(forKey: TPPSettings.userHasSeenWelcomeScreenKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: TPPSettings.userHasSeenWelcomeScreenKey)
    }
  }

  var userPresentedAgeCheck: Bool {
    get {
      UserDefaults.standard.bool(forKey: TPPSettings.userPresentedAgeCheckKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: TPPSettings.userPresentedAgeCheckKey)
    }
  }

  var userHasAcceptedEULA: Bool {
    get {
      UserDefaults.standard.bool(forKey: TPPSettings.userHasAcceptedEULAKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: TPPSettings.userHasAcceptedEULAKey)
    }
  }

  var useBetaLibraries: Bool {
    get {
      UserDefaults.standard.bool(forKey: TPPSettings.useBetaLibrariesKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: TPPSettings.useBetaLibrariesKey)
      NotificationCenter.default.post(
        name: NSNotification.Name.TPPUseBetaDidChange,
        object: self
      )
    }
  }

  var appVersion: String? {
    get {
      UserDefaults.standard.string(forKey: TPPSettings.versionKey)
    }
    set(versionString) {
      UserDefaults.standard.set(versionString, forKey: TPPSettings.versionKey)
    }
  }

  var customLibraryRegistryServer: String? {
    get {
      UserDefaults.standard.string(forKey: TPPSettings.customLibraryRegistryKey)
    }
    set(customServer) {
      UserDefaults.standard.set(customServer, forKey: TPPSettings.customLibraryRegistryKey)
    }
  }

  var enterLCPPassphraseManually: Bool {
    get {
      UserDefaults.standard.bool(forKey: TPPSettings.enterLCPPassphraseManually)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: TPPSettings.enterLCPPassphraseManually)
    }
  }
}
