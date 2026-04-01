import Foundation
import Combine

@objc protocol NYPLUniversalLinksSettings: NSObjectProtocol {
    /// The URL that will be used to redirect an external authentication flow
    /// back to the our app. This URL will need to be provided to the external
    /// service. For example, Clever authentication uses this URL to redirect
    /// to the app after authenticating in Safari.
    var universalLinksURL: URL { get }
}

@objc protocol NYPLFeedURLProvider {
    var accountMainFeedURL: URL? { get set }
}

@objcMembers class TPPSettings: NSObject, NYPLFeedURLProvider, TPPAgeCheckChoiceStorage {
    static let shared = TPPSettings()

    class func sharedSettings() -> TPPSettings {
        return TPPSettings.shared
    }

    // MARK: - Combine Publishers

    /// Publishes when any setting changes (replaces `.TPPSettingsDidChange` notification)
    private let settingsChangedSubject = PassthroughSubject<Void, Never>()

    /// Publisher for settings changes. Use instead of observing `.TPPSettingsDidChange`.
    var settingsDidChange: AnyPublisher<Void, Never> {
        settingsChangedSubject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Publishes when the beta libraries toggle changes (replaces `.TPPUseBetaDidChange` notification)
    private let useBetaChangedSubject = PassthroughSubject<Bool, Never>()

    /// Publisher for beta libraries toggle. Use instead of observing `.TPPUseBetaDidChange`.
    var useBetaDidChange: AnyPublisher<Bool, Never> {
        useBetaChangedSubject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    static let TPPAboutPalaceURLString = "http://thepalaceproject.org/"
    static let TPPUserAgreementURLString = "https://legal.palaceproject.io/End%20User%20License%20Agreement.html"
    static let TPPPrivacyPolicyURLString = "https://legal.palaceproject.io/Privacy%20Policy.html"
    static let TPPSoftwareLicensesURLString = "https://legal.palaceproject.io/software-licenses.html"

    static private let customMainFeedURLKey = "NYPLSettingsCustomMainFeedURL"
    static private let accountMainFeedURLKey = "NYPLSettingsAccountMainFeedURL"
    static private let userPresentedAgeCheckKey = "NYPLUserPresentedAgeCheckKey"
    static let userHasAcceptedEULAKey = "NYPLSettingsUserAcceptedEULA"
    static private let userSeenFirstTimeSyncMessageKey = "userSeenFirstTimeSyncMessageKey"
    static private let useBetaLibrariesKey = "NYPLUseBetaLibrariesKey"
    static let settingsLibraryAccountsKey = "NYPLSettingsLibraryAccountsKey"
    static private let versionKey = "NYPLSettingsVersionKey"
    static private let customLibraryRegistryKey = "TPPSettingsCustomLibraryRegistryKey"
    static private let enterLCPPassphraseManually = "TPPSettingsEnterLCPPassphraseManually"
    static let showDeveloperSettingsKey = "showDeveloperSettings"
    static private let downloadOnlyOnWiFiKey = "TPPSettingsDownloadOnlyOnWiFi"

    // Set to nil (the default) if no custom feed should be used.
    var customMainFeedURL: URL? {
        get {
            return UserDefaults.standard.url(forKey: TPPSettings.customMainFeedURLKey)
        }
        set(customUrl) {
            if customUrl == self.customMainFeedURL {
                return
            }
            UserDefaults.standard.set(customUrl, forKey: TPPSettings.customMainFeedURLKey)
            settingsChangedSubject.send()
            NotificationCenter.default.post(name: Notification.Name.TPPSettingsDidChange, object: self)
        }
    }

    var accountMainFeedURL: URL? {
        get {
            return UserDefaults.standard.url(forKey: TPPSettings.accountMainFeedURLKey)
        }
        set(mainFeedUrl) {
            if mainFeedUrl == self.accountMainFeedURL {
                return
            }
            UserDefaults.standard.set(mainFeedUrl, forKey: TPPSettings.accountMainFeedURLKey)
            settingsChangedSubject.send()
            NotificationCenter.default.post(name: Notification.Name.TPPSettingsDidChange, object: self)
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
            useBetaChangedSubject.send(newValue)
            NotificationCenter.default.post(name: NSNotification.Name.TPPUseBetaDidChange,
                                            object: self)
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

    var downloadOnlyOnWiFi: Bool {
        get {
            UserDefaults.standard.bool(forKey: TPPSettings.downloadOnlyOnWiFiKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: TPPSettings.downloadOnlyOnWiFiKey)
        }
    }

}
