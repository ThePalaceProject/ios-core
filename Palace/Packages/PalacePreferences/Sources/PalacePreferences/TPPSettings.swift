import Foundation
import Combine

public final class TPPSettings {

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
    }

    // MARK: - Change streams

    /// Each change of the beta-libraries switch, on main. A stream on the type,
    /// not on each instance: settings screens and `AccountsManager` each build
    /// their own `TPPSettings` over the same defaults, and the account list
    /// must follow a switch flipped on any of them.
    // PUBLIC_INTENT: AccountsManager (app target) follows the beta-libraries switch.
    public static var useBetaLibrariesChanges: AnyPublisher<Bool, Never> {
        useBetaLibrariesChannel.subject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private static let useBetaLibrariesChannel = SettingsChangeChannel<Bool>()

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
    // PUBLIC_INTENT: the DEBUG UI-test launch hook registers this key in the
    // app's registration domain, the same way `settingsLibraryAccountsKey` is read.
    public static let customLibraryRegistryKey = "TPPSettingsCustomLibraryRegistryKey"
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
            Self.useBetaLibrariesChannel.subject.send(newValue)
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

/// A process-wide change stream for a setting. `@unchecked Sendable`: the only
/// state is the `let` subject, and Combine subjects lock around `send`.
final class SettingsChangeChannel<Value>: @unchecked Sendable {
    let subject = PassthroughSubject<Value, Never>()
}
