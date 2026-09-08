//
//  TPPSettingsView.swift
//  Palace
//
//  Created by Maurice Carrier on 12/2/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI
import PalacePreferences
import PalaceUIKit
import PalaceBookModel
import PalaceBookRegistry
import TriageBotCore

struct TPPSettingsView: View {
    typealias DisplayStrings = Strings.Settings

    @AppStorage(TPPSettings.showDeveloperSettingsKey) private var showDeveloperSettings: Bool = false
    @AppStorage(TPPSettings.downloadOnlyOnWiFiKey) private var downloadOnlyOnWiFi: Bool = false
    // PP-4712: patron-configurable audiobook skip intervals (seconds), bound to
    // the same UserDefaults keys the player reads via AudiobookSkipIntervalSettings.
    @AppStorage(AudiobookSkipIntervalSettings.forwardKey) private var skipForwardInterval: Int = AudiobookSkipIntervalSettings.defaultInterval
    @AppStorage(AudiobookSkipIntervalSettings.backKey) private var skipBackInterval: Int = AudiobookSkipIntervalSettings.defaultInterval
    /// Subscribes to the dev-settings triage bot local override so the
    /// support section appears/disappears the moment the toggle flips.
    /// Effective gating still goes through
    /// `appContainer.featureFlags.isTriageBotEnabled` (which folds in the
    /// DEBUG-default-on and Firebase fallback). The @AppStorage read in
    /// `supportSection` registers the SwiftUI observation.
    @AppStorage("RemoteFeatureFlags.triageBotLocalOverride") private var triageBotLocalOverride: Bool = false
    /// Subscribes to the side-loading local override so the "Side Loading"
    /// section appears/disappears the moment the dev-menu toggle flips.
    /// Effective gating still runs through
    /// `appContainer.featureFlags.isSideLoadingEnabled` (read in
    /// `sideLoadingSection`), whose precedence is local override > Firebase
    /// remote (default off); this @AppStorage read registers the observation.
    @AppStorage(RemoteFeatureFlags.sideLoadingLocalOverrideKey) private var sideLoadingLocalOverride: Bool = false
    /// PP-4884: the patron's "Include diagnostics" choice. Bound to the exact
    /// key the triage bot's gating context provider reads
    /// (`UserDefaultsDiagnosticsPreference.defaultsKey`), so flipping this switch
    /// changes what the bot collects with no other wiring. Default ON — the bot
    /// is most useful to support with full context; a privacy-conscious patron
    /// can turn it off to send only app + device version.
    @AppStorage(UserDefaultsDiagnosticsPreference.defaultsKey) private var includeTriageDiagnostics: Bool = true
    /// Feature-flag read seam (Wave 1b), resolved from the environment.
    @Environment(\.appContainer) private var appContainer
    @State private var selectedView: Int? = 0

    /// PP-5098 removed the iPad two-column shape this screen used to build for
    /// itself.
    ///
    /// It was a `NavigationView(.columns)` gated on `UIDevice.current
    /// .orientation`, whose detail column started empty *because the library
    /// list was inline in the master column* (PP-917). That reason is gone with
    /// the list, and the shape it left behind was a 2021 fossil: `AppTabHostView`
    /// already wraps this view in `NavigationHostView`, a `NavigationStack`, so
    /// iPad landscape was nesting a deprecated `NavigationView` inside a
    /// navigation stack — and only in landscape, because the gate was already
    /// false in portrait. Deleting it removes a shape that flipped on rotation
    /// rather than introducing a new one, and takes the unreliable
    /// `UIDevice.current.orientation` read with it. Settings → Libraries →
    /// Library Details is now one push chain on every idiom.
    ///
    /// Deliberately NOT replaced with `horizontalSizeClass` — that would be
    /// building the split view this change declined.
    var body: some View {
        listView
    }

    @ViewBuilder private var listView: some View {
        List {
            librariesEntrySection
            downloadsSection
            playbackSection
            supportSection
            advancedSection
            sideLoadingSection
            infoSection
            developerSettingsSection
        }
        .navigationBarTitle(DisplayStrings.settings)
        .listStyle(GroupedListStyle())
    }

    /// PP-5098: the entry point to the dedicated Libraries screen, which
    /// replaces the inline MY LIBRARIES list that used to sit here. First row
    /// on the tab, so the rest of Settings is visible without scrolling past a
    /// library list of any length.
    @ViewBuilder private var librariesEntrySection: some View {
        Section {
            NavigationLink(
                destination: LibrariesView(appContainer: appContainer),
                tag: 1,
                selection: self.$selectedView
            ) {
                HStack(spacing: 12) {
                    // Monochrome by house convention — Palace chrome does not
                    // tint its affordances.
                    Image(systemName: "building.columns")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(DisplayStrings.libraries)
                            .palaceFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(DisplayStrings.librariesEntrySubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.manageLibrariesButton)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(DisplayStrings.libraries). \(DisplayStrings.librariesEntrySubtitle)")
        }
    }

    @ViewBuilder private var downloadsSection: some View {
        Section(header: Text(DisplayStrings.downloads)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(DisplayStrings.downloadOnlyOnWiFi, isOn: $downloadOnlyOnWiFi)
                    .tint(.green)
                    .accessibilityIdentifier(AccessibilityID.Settings.downloadOnlyOnWiFiToggle)
                    .accessibilityLabel(DisplayStrings.downloadOnlyOnWiFi)
                Text(DisplayStrings.downloadOnlyOnWiFiDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // PP-4712: audiobook skip-interval controls. Each direction is independent;
    // the pickers only offer valid options, so no out-of-range value can be set.
    @ViewBuilder private var playbackSection: some View {
        Section(header: Text(DisplayStrings.playback)) {
            Picker(DisplayStrings.skipForwardInterval, selection: $skipForwardInterval) {
                ForEach(AudiobookSkipIntervalSettings.options, id: \.self) { seconds in
                    Text(DisplayStrings.skipIntervalSeconds(seconds)).tag(seconds)
                }
            }
            .accessibilityIdentifier("settings.skipForwardInterval")
            .accessibilityLabel(DisplayStrings.skipForwardInterval)
            Picker(DisplayStrings.skipBackInterval, selection: $skipBackInterval) {
                ForEach(AudiobookSkipIntervalSettings.options, id: \.self) { seconds in
                    Text(DisplayStrings.skipIntervalSeconds(seconds)).tag(seconds)
                }
            }
            .accessibilityIdentifier("settings.skipBackInterval")
            .accessibilityLabel(DisplayStrings.skipBackInterval)
            Text(DisplayStrings.skipIntervalDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var supportSection: some View {
        // Row visibility depends ONLY on the kill-switch (cheap UserDefaults
        // check). The view factory runs at navigation time inside
        // TriageBotSupportView's body, NOT here — chaos-qa F-005 found that
        // calling the factory from every supportSection re-render could
        // intermittently return nil after bg/fg cycling, silently hiding
        // the row. With this shape the row is stable as long as the
        // flag is on; any factory failure surfaces as an UnavailableView
        // inside the chat surface instead of a disappeared Settings row.
        // Touching `triageBotLocalOverride` registers the @AppStorage
        // dependency; the effective value still folds in DEBUG-default-on
        // and Firebase via `isTriageBotEnabled`.
        let _ = triageBotLocalOverride
        // PP-4542 / F-012: the Support section must ALWAYS render. When the
        // triage bot is off (production Firebase default), fall back to the
        // legacy email report path so support stays reachable.
        let decision = SupportSectionDecision.decide(
            isTriageBotEnabled: appContainer.featureFlags.isTriageBotEnabled,
            currentAccount: AppContainer.production().accountsManager.currentAccount
        )
        Section(header: Text("Support")) {
            switch decision {
            case .triageBot:
                let chat = TriageBotSupportView()
                let wrapper = chat.anyView()
                row(title: "Get Help", index: 10, selection: self.$selectedView, destination: wrapper)
                    .accessibilityIdentifier("settings.row.getHelp")
                    .accessibilityLabel("Get Help — chat with our support bot")
                // PP-4884: give a privacy-conscious patron a way to send fewer
                // diagnostics. Only shown when the bot is active (the toggle is
                // moot when no support ticket is ever assembled). The bot honors
                // this via DiagnosticsGatingContextProvider — no other wiring.
                // COPY PENDING PRODUCT SIGN-OFF (PP-4884 done-criterion).
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $includeTriageDiagnostics) {
                        Text("Include diagnostics")
                            .palaceFont(.body)
                    }
                    .accessibilityIdentifier("settings.row.includeDiagnostics")
                    Text("When on, a support ticket includes your app and device version, network state, and a short tail of recent activity so support can solve problems faster. Turn it off to send only your app and device version.")
                        .palaceFont(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .legacyEmail(let address):
                Button {
                    presentLegacyReportIssue(to: address)
                } label: {
                    Text(DisplayStrings.reportIssue)
                        .palaceFont(.body)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.row.reportIssue")
                .accessibilityLabel(DisplayStrings.reportIssue)
            }
        }
    }

    /// Opens the legacy problem-report email composer. `beginComposing`
    /// already handles the no-mail-configured case with an alert, so the row
    /// is always safe to offer. Mirrors `AccountDetailView.handleReportIssue`.
    private func presentLegacyReportIssue(to address: String) {
        guard let topVC = topViewController() else { return }
        let accountsManager = AppContainer.production().accountsManager
        let ctx = accountsManager.problemReportContext(forLibrary: accountsManager.currentAccount?.uuid)
        ProblemReportEmail.sharedInstance.beginComposing(
            to: address,
            presentingViewController: topVC,
            book: nil as TPPBook?,
            patronIdentifier: ctx.patronIdentifier,
            libraryName: ctx.libraryName,
            libraryUUID: ctx.libraryUUID
        )
    }

    private func topViewController() -> UIViewController? {
        guard let root = UIApplication.shared.mainKeyWindow?.rootViewController else {
            return nil
        }
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }

    /// PP-2677 side-loading: a test-only entry to the Side Loading screen,
    /// rendered ONLY when the feature flag is on. Row visibility depends on the
    /// cheap flag read; the import/manage machinery lives inside
    /// `SideLoadingView` and is resolved lazily at navigation time.
    @ViewBuilder private var sideLoadingSection: some View {
        // Register the @AppStorage observation so the section shows/hides the
        // instant the dev-menu override flips; effective value still runs
        // through isSideLoadingEnabled (local override > Firebase remote) below.
        let _ = sideLoadingLocalOverride
        if appContainer.featureFlags.isSideLoadingEnabled {
            Section(header: Text("Side Loading")) {
                let destination = SideLoadingView(
                    manager: AppContainer.production().sideloadedBookManager
                ).anyView()
                row(title: "Side Loading", index: 11, selection: self.$selectedView, destination: destination)
                    .accessibilityIdentifier("settings.row.sideLoading")
            }
        }
    }

    @ViewBuilder private var infoSection: some View {
        let view: AnyView = showDeveloperSettings ? EmptyView().anyView() : versionInfo.anyView()
        Section(header: Text(Strings.Settings.aboutSectionHeader), footer: view) {
            aboutRow
            privacyRow
            userAgreementRow
            softwareLicenseRow
        }
    }

    // swiftlint:disable:next force_unwrapping
    private static let fallbackURL = URL(string: "https://thepalaceproject.org")!

    @ViewBuilder private var aboutRow: some View {
        let viewController = RemoteHTMLViewController(
            URL: URL(string: TPPSettings.TPPAboutPalaceURLString) ?? Self.fallbackURL,
            title: Strings.Settings.aboutApp,
            failureMessage: Strings.Error.loadFailedError
        )

        let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
            .navigationBarTitle(Text(DisplayStrings.aboutApp))

        row(title: DisplayStrings.aboutApp, index: 2, selection: self.$selectedView, destination: wrapper.anyView())
            .accessibilityIdentifier(AccessibilityID.Settings.aboutPalaceButton)
    }

    @ViewBuilder private var privacyRow: some View {
        let viewController = RemoteHTMLViewController(
            URL: URL(string: TPPSettings.TPPPrivacyPolicyURLString) ?? Self.fallbackURL,
            title: Strings.Settings.privacyPolicy,
            failureMessage: Strings.Error.loadFailedError
        )

        let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
            .navigationBarTitle(Text(DisplayStrings.privacyPolicy))

        row(title: DisplayStrings.privacyPolicy, index: 3, selection: self.$selectedView, destination: wrapper.anyView())
            .accessibilityIdentifier(AccessibilityID.Settings.privacyPolicyButton)
    }

    @ViewBuilder private var userAgreementRow: some View {
        let viewController = RemoteHTMLViewController(
            URL: URL(string: TPPSettings.TPPUserAgreementURLString) ?? Self.fallbackURL,
            title: Strings.Settings.eula,
            failureMessage: Strings.Error.loadFailedError
        )

        let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
            .navigationBarTitle(Text(DisplayStrings.eula))

        row(title: DisplayStrings.eula, index: 4, selection: self.$selectedView, destination: wrapper.anyView())
            .accessibilityIdentifier(AccessibilityID.Settings.userAgreementButton)
    }

    @ViewBuilder private var softwareLicenseRow: some View {
        let viewController = RemoteHTMLViewController(
            URL: URL(string: TPPSettings.TPPSoftwareLicensesURLString) ?? Self.fallbackURL,
            title: Strings.Settings.softwareLicenses,
            failureMessage: Strings.Error.loadFailedError
        )

        let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
            .navigationBarTitle(Text(DisplayStrings.softwareLicenses))

        row(title: DisplayStrings.softwareLicenses, index: 5, selection: self.$selectedView, destination: wrapper.anyView())
            .accessibilityIdentifier(AccessibilityID.Settings.softwareLicensesButton)
    }

    /// PP-4788: always-visible Advanced menu (no gesture required) hosting the
    /// patron-facing support functions — Send Error Logs + Data & Reset — that
    /// previously lived only in the gesture-gated Testing menu. Support can now
    /// direct patrons here without walking them through the hidden long-press.
    @ViewBuilder private var advancedSection: some View {
        Section {
            row(title: DisplayStrings.advanced, index: 7, selection: self.$selectedView,
                destination: AppAdvancedSettingsView()
                    .navigationBarTitle(Text(DisplayStrings.advanced))
                    .anyView())
                .accessibilityIdentifier(AccessibilityID.Settings.advancedButton)
        }
    }

    @ViewBuilder private var developerSettingsSection: some View {
        if AppContainer.production().settings.customMainFeedURL == nil && showDeveloperSettings {
            Section(header: Text(DisplayStrings.developerSettings).accessibilityHidden(true), footer: versionInfo) {
                // PP-4788: the Testing screen is now SwiftUI (DeveloperSettingsView),
                // replacing TPPDeveloperSettingsTableViewController. Still gated on the
                // version-number long-press unlock (showDeveloperSettings) — unchanged.
                // Engineering-tier sections only; the patron-facing Send Error Logs +
                // Data & Reset now live in the always-visible Advanced menu below.
                row(title: DisplayStrings.developerSettings, index: 6, selection: self.$selectedView,
                    destination: DeveloperSettingsView()
                        .navigationBarTitle(Text(DisplayStrings.developerSettings))
                        .anyView())
            }
        }
    }

    @ViewBuilder private var versionInfo: some View {
        let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Palace"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: (kCFBundleVersionKey as String)) as? String ?? "Unknown"

        Text("\(productName) version \(version) (\(build))")
            .palaceFont(size: 12)
            .gesture(
                LongPressGesture(minimumDuration: 5.0)
                    .onEnded { _ in
                        self.showDeveloperSettings.toggle()
                    }
            )
            .frame(height: 40)
            .horizontallyCentered()
    }

    private func row(title: String, index: Int, selection: Binding<Int?>, destination: AnyView) -> some View {
        NavigationLink(
            destination: destination,
            tag: index,
            selection: selection,
            label: {
                Text(title)
                    .palaceFont(.body)
            }
        )
    }
}

// MARK: - SupportSectionDecision

/// Pure decision for what the Settings "Support" section should present.
///
/// PP-4542 / F-012: the section must NEVER be empty. When the triage bot is
/// enabled it routes to the chat surface; otherwise it routes to the legacy
/// email problem-report flow with a guaranteed-non-empty address (the current
/// library's support email, or the general Palace fallback).
enum SupportSectionDecision: Equatable {
    case triageBot
    case legacyEmail(address: String)

    /// General fallback when no library-specific support email is available.
    static let generalFallbackEmail = "support@thepalaceproject.org"

    /// The email the view should hand to `beginComposing(to:)`, or `nil` for
    /// the triage-bot path.
    var emailAddress: String? {
        switch self {
        case .triageBot: return nil
        case .legacyEmail(let address): return address
        }
    }

    /// Core decision. Operates on the already-resolved support-email string so
    /// the branch + fallback logic is fixture-free testable.
    static func decide(isTriageBotEnabled: Bool, supportEmail: String?) -> SupportSectionDecision {
        if isTriageBotEnabled {
            return .triageBot
        }
        if let email = supportEmail, !email.isEmpty {
            return .legacyEmail(address: email)
        }
        return .legacyEmail(address: generalFallbackEmail)
    }

    /// Convenience used by the view: resolves the current account's support
    /// email before deciding.
    static func decide(isTriageBotEnabled: Bool, currentAccount: Account?) -> SupportSectionDecision {
        decide(
            isTriageBotEnabled: isTriageBotEnabled,
            supportEmail: currentAccount?.supportEmail?.rawValue
        )
    }
}
