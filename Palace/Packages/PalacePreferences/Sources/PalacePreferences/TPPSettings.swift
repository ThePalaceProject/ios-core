import Foundation
import Combine

@objcMembers public class TPPSettings: NSObject {

    // MARK: - Dependencies

    /// `UserDefaults` backing store. Production callers use the no-arg
    /// initializer which binds `.standard`; tests inject a per-suite
    /// `UserDefaults(suiteName:)` via the explicit initializer so
    /// two tests touching the same key cannot pollute each other.
    /// There is NO fallback — once injected, every read/write below
    /// goes through `defaults` only.
    private let defaults: UserDefaults

    /// Designated initializer. Defaults to `.standard` so all
    /// production call sites stay green; tests pass a fresh suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    // MARK: - Combine Publishers

    /// Publishes when any setting changes (replaces `.TPPSettingsDidChange` notification)
    private let settingsChangedSubject = PassthroughSubject<Void, Never>()

    /// Publisher for settings changes. Use instead of observing `.TPPSettingsDidChange`.
    public var settingsDidChange: AnyPublisher<Void, Never> {
        settingsChangedSubject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Publishes when the beta libraries toggle changes (replaces `.TPPUseBetaDidChange` notification)
    private let useBetaChangedSubject = PassthroughSubject<Bool, Never>()

    /// Publisher for beta libraries toggle. Use instead of observing `.TPPUseBetaDidChange`.
    public var useBetaDidChange: AnyPublisher<Bool, Never> {
        useBetaChangedSubject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    public static let TPPAboutPalaceURLString = "http://thepalaceproject.org/"
    public static let TPPUserAgreementURLString = "https://legal.palaceproject.io/End%20User%20License%20Agreement.html"
    public static let TPPPrivacyPolicyURLString = "https://legal.palaceproject.io/Privacy%20Policy.html"
    public static let TPPSoftwareLicensesURLString = "https://legal.palaceproject.io/software-licenses.html"

    static private let customMainFeedURLKey = "NYPLSettingsCustomMainFeedURL"
    static private let accountMainFeedURLKey = "NYPLSettingsAccountMainFeedURL"
    static private let userPresentedAgeCheckKey = "NYPLUserPresentedAgeCheckKey"
    public static let userHasAcceptedEULAKey = "NYPLSettingsUserAcceptedEULA"
    static private let userSeenFirstTimeSyncMessageKey = "userSeenFirstTimeSyncMessageKey"
    static private let useBetaLibrariesKey = "NYPLUseBetaLibrariesKey"
    public static let settingsLibraryAccountsKey = "NYPLSettingsLibraryAccountsKey"
    static private let versionKey = "NYPLSettingsVersionKey"
    static private let customLibraryRegistryKey = "TPPSettingsCustomLibraryRegistryKey"
    static private let enterLCPPassphraseManually = "TPPSettingsEnterLCPPassphraseManually"
    public static let showDeveloperSettingsKey = "showDeveloperSettings"
    public static let downloadOnlyOnWiFiKey = "TPPSettingsDownloadOnlyOnWiFi"

    // App-rating engagement signals (PP-4087). Local/on-device only; no PII.
    // Kept on `UserDefaults` so they survive app updates.
    static private let appRatingSessionCountKey = "TPPAppRatingSessionCount"
    static private let appRatingBooksCompletedKey = "TPPAppRatingBooksCompleted"
    static private let appRatingLastPromptDateKey = "TPPAppRatingLastPromptDate"
    static private let appRatingPromptDisplayCountKey = "TPPAppRatingPromptDisplayCount"
    static private let appRatingDismissalCountKey = "TPPAppRatingDismissalCount"
    static private let appRatingOptedOutKey = "TPPAppRatingOptedOut"
    static private let appRatingCrashFreeLastSessionKey = "TPPAppRatingCrashFreeLastSession"

    // Set to nil (the default) if no custom feed should be used.
    public var customMainFeedURL: URL? {
        get {
            return defaults.url(forKey: TPPSettings.customMainFeedURLKey)
        }
        set(customUrl) {
            if customUrl == self.customMainFeedURL {
                return
            }
            defaults.set(customUrl, forKey: TPPSettings.customMainFeedURLKey)
            settingsChangedSubject.send()
            NotificationCenter.default.post(name: Notification.Name.TPPSettingsDidChange, object: self)
        }
    }

    public var accountMainFeedURL: URL? {
        get {
            return defaults.url(forKey: TPPSettings.accountMainFeedURLKey)
        }
        set(mainFeedUrl) {
            if mainFeedUrl == self.accountMainFeedURL {
                return
            }
            defaults.set(mainFeedUrl, forKey: TPPSettings.accountMainFeedURLKey)
            settingsChangedSubject.send()
            NotificationCenter.default.post(name: Notification.Name.TPPSettingsDidChange, object: self)
        }
    }

    public var userPresentedAgeCheck: Bool {
        get {
            defaults.bool(forKey: TPPSettings.userPresentedAgeCheckKey)
        }
        set {
            defaults.set(newValue, forKey: TPPSettings.userPresentedAgeCheckKey)
        }
    }

    public var userHasAcceptedEULA: Bool {
        get {
            defaults.bool(forKey: TPPSettings.userHasAcceptedEULAKey)
        }
        set {
            defaults.set(newValue, forKey: TPPSettings.userHasAcceptedEULAKey)
        }
    }

    public var useBetaLibraries: Bool {
        get {
            defaults.bool(forKey: TPPSettings.useBetaLibrariesKey)
        }
        set {
            defaults.set(newValue, forKey: TPPSettings.useBetaLibrariesKey)
            useBetaChangedSubject.send(newValue)
            NotificationCenter.default.post(name: NSNotification.Name.TPPUseBetaDidChange,
                                            object: self)
        }
    }

    public var appVersion: String? {
        get {
            defaults.string(forKey: TPPSettings.versionKey)
        }
        set(versionString) {
            defaults.set(versionString, forKey: TPPSettings.versionKey)
        }
    }

    public var customLibraryRegistryServer: String? {
        get {
            defaults.string(forKey: TPPSettings.customLibraryRegistryKey)
        }
        set(customServer) {
            defaults.set(customServer, forKey: TPPSettings.customLibraryRegistryKey)
        }
    }

    public var enterLCPPassphraseManually: Bool {
        get {
            defaults.bool(forKey: TPPSettings.enterLCPPassphraseManually)
        }
        set {
            defaults.set(newValue, forKey: TPPSettings.enterLCPPassphraseManually)
        }
    }

    public var downloadOnlyOnWiFi: Bool {
        get {
            defaults.bool(forKey: TPPSettings.downloadOnlyOnWiFiKey)
        }
        set {
            defaults.set(newValue, forKey: TPPSettings.downloadOnlyOnWiFiKey)
        }
    }

    // MARK: - App Rating (PP-4087)

    public var appRatingSessionCount: Int {
        get { defaults.integer(forKey: TPPSettings.appRatingSessionCountKey) }
        set { defaults.set(newValue, forKey: TPPSettings.appRatingSessionCountKey) }
    }

    public var appRatingBooksCompleted: Int {
        get { defaults.integer(forKey: TPPSettings.appRatingBooksCompletedKey) }
        set { defaults.set(newValue, forKey: TPPSettings.appRatingBooksCompletedKey) }
    }

    public var appRatingLastPromptDate: Date? {
        get { defaults.object(forKey: TPPSettings.appRatingLastPromptDateKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: TPPSettings.appRatingLastPromptDateKey)
            } else {
                defaults.removeObject(forKey: TPPSettings.appRatingLastPromptDateKey)
            }
        }
    }

    public var appRatingPromptDisplayCount: Int {
        get { defaults.integer(forKey: TPPSettings.appRatingPromptDisplayCountKey) }
        set { defaults.set(newValue, forKey: TPPSettings.appRatingPromptDisplayCountKey) }
    }

    public var appRatingDismissalCount: Int {
        get { defaults.integer(forKey: TPPSettings.appRatingDismissalCountKey) }
        set { defaults.set(newValue, forKey: TPPSettings.appRatingDismissalCountKey) }
    }

    public var appRatingOptedOut: Bool {
        get { defaults.bool(forKey: TPPSettings.appRatingOptedOutKey) }
        set { defaults.set(newValue, forKey: TPPSettings.appRatingOptedOutKey) }
    }

    /// Defaults to `true` (assume crash-free) when no session has recorded a
    /// value yet, so a never-crashed patron is not blocked by an absent key.
    public var appRatingCrashFreeLastSession: Bool {
        get {
            defaults.object(forKey: TPPSettings.appRatingCrashFreeLastSessionKey) == nil
                ? true
                : defaults.bool(forKey: TPPSettings.appRatingCrashFreeLastSessionKey)
        }
        set { defaults.set(newValue, forKey: TPPSettings.appRatingCrashFreeLastSessionKey) }
    }

}
