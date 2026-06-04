//
//  TPPSettingsView.swift
//  Palace
//
//  Created by Maurice Carrier on 12/2/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

struct TPPSettingsView: View {
    typealias DisplayStrings = Strings.Settings

    @AppStorage(TPPSettings.showDeveloperSettingsKey) private var showDeveloperSettings: Bool = false
    @AppStorage(TPPSettings.downloadOnlyOnWiFiKey) private var downloadOnlyOnWiFi: Bool = false
    /// Subscribes to the dev-settings triage bot local override so the
    /// support section appears/disappears the moment the toggle flips.
    /// Effective gating still goes through
    /// `RemoteFeatureFlags.shared.isTriageBotEnabled` (which folds in the
    /// DEBUG-default-on and Firebase fallback). The @AppStorage read in
    /// `supportSection` registers the SwiftUI observation.
    @AppStorage("RemoteFeatureFlags.triageBotLocalOverride") private var triageBotLocalOverride: Bool = false
    @State private var selectedView: Int? = 0
    @State private var orientation: UIDeviceOrientation = UIDevice.current.orientation
    @State private var switchPromptAccount: Account? = nil
    @StateObject private var librariesVM: LibrariesSectionViewModel

    init() {
        let container = AppContainer.production()
        let env = ProductionLibrariesSectionEnvironment(
            accountsManager: container.accountsManager,
            settings: container.settings
        )
        _librariesVM = StateObject(wrappedValue: LibrariesSectionViewModel(environment: env))
    }

    private var sideBarEnabled: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            &&  UIDevice.current.orientation != .portrait
            &&  UIDevice.current.orientation != .portraitUpsideDown
    }

    var body: some View {
        ZStack {
            if sideBarEnabled {
                NavigationView {
                    listView
                        .navigationTitle(DisplayStrings.settings)
                    placeholderDetail
                }
                .navigationViewStyle(.columns)
            } else {
                listView
            }

            // Loading overlay during a library switch. Stays up while the
            // auth document loads — when the view model fires its
            // completion the overlay dismisses + the tab jumps to Catalog
            // in the same beat, so the user lands on data that has
            // started populating instead of a stale-then-refreshing
            // catalog.
            if librariesVM.isSwitching {
                switchingOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: librariesVM.isSwitching)
    }

    @ViewBuilder private var switchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(DisplayStrings.switchingLibrary)
                    .palaceFont(.body)
                    .foregroundColor(.white)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.6))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(DisplayStrings.switchingLibrary)
    }

    /// Placeholder shown in the iPad sidebar's detail column before the
    /// user taps a row. The library list itself is now inline in the
    /// master column (PP-917), so the detail column starts empty.
    @ViewBuilder private var placeholderDetail: some View {
        Text(DisplayStrings.settings)
            .palaceFont(.body)
            .foregroundColor(.secondary)
    }

    @ViewBuilder private var listView: some View {
        List {
            librariesSection
            downloadsSection
            supportSection
            infoSection
            developerSettingsSection
        }
        .navigationBarTitle(DisplayStrings.settings)
        .listStyle(GroupedListStyle())
        .onAppear {
            librariesVM.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            self.orientation = UIDevice.current.orientation
        }
        .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)) { _ in
            librariesVM.refresh()
        }
        .sheet(isPresented: $librariesVM.showAddLibrarySheet) {
            UIViewControllerWrapper(
                TPPAccountList { account in
                    DispatchQueue.main.async {
                        // Adding a library goes through the same switch
                        // chain as tapping an existing row: dismiss the
                        // picker, show the loading overlay while the auth
                        // doc loads, then jump to the Catalog tab so the
                        // user lands in the new library instead of being
                        // parked on Settings.
                        librariesVM.showAddLibrarySheet = false
                        librariesVM.switchToAccount(account) {
                            AppContainer.production().tabRouterHub.navigate(to: .catalog)
                        }
                    }
                },
                updater: { _ in }
            )
        }
    }

    @ViewBuilder private var librariesSection: some View {
        Section(header: librariesSectionHeader) {
            ForEach(librariesVM.accounts, id: \.uuid) { account in
                libraryRow(for: account)
                    .accessibilityIdentifier("\(AccessibilityID.Settings.accountSection).\(account.uuid)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if account.uuid != librariesVM.currentAccountUUID {
                            Button(role: .destructive) {
                                librariesVM.deleteSecondary(account)
                            } label: {
                                Label(Strings.Generic.delete, systemImage: "trash")
                            }
                            // The app-wide accent overrides the destructive
                            // role's default; pin the iOS-standard red.
                            .tint(.red)
                        }
                    }
            }
        }
        .confirmationDialog(
            switchPromptTitle,
            isPresented: Binding(
                get: { switchPromptAccount != nil },
                set: { isPresented in if !isPresented { switchPromptAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            // Yes → switch + jump to Catalog tab (the prototype behavior).
            // The loading overlay (see `.overlay` below) stays up while
            // the auth doc loads; we time the tab jump to the completion
            // so the catalog opens with data already populated, not a
            // stale-then-refreshing screen.
            Button(Strings.Generic.yes) {
                if let account = switchPromptAccount {
                    librariesVM.switchToAccount(account) {
                        AppContainer.production().tabRouterHub.navigate(to: .catalog)
                    }
                }
                switchPromptAccount = nil
            }
            // Destructive role gives the iOS-standard red "No" used in the
            // prototype to distinguish from the neutral "Cancel".
            Button(Strings.Generic.no, role: .destructive) {
                switchPromptAccount = nil
            }
            Button(Strings.Generic.cancel, role: .cancel) {
                switchPromptAccount = nil
            }
        }
    }

    private var switchPromptTitle: String {
        guard let name = switchPromptAccount?.name else { return "" }
        return String(format: DisplayStrings.switchLibraryPromptFormat, name)
    }

    /// Builds one library row. The active library uses a NavigationLink
    /// (tap → manage credentials / AccountDetailView). An inactive library
    /// uses a Button (tap → confirm-and-switch action sheet) so the user
    /// can switch between libraries without going through a sign-in flow.
    @ViewBuilder private func libraryRow(for account: Account) -> some View {
        let isCurrent = account.uuid == librariesVM.currentAccountUUID
        if isCurrent {
            NavigationLink(destination: accountDetail(for: account)) {
                LibraryRowView(account: account, isCurrent: true)
            }
        } else {
            Button {
                switchPromptAccount = account
            } label: {
                LibraryRowView(account: account, isCurrent: false)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var librariesSectionHeader: some View {
        HStack {
            Text(DisplayStrings.libraries)
            Spacer()
            Button {
                librariesVM.presentAddLibrary()
            } label: {
                // Match the surrounding section-header text style so the
                // button reads as part of the header rather than an oversized
                // affordance: footnote weight, tight + icon, uppercase.
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Text(DisplayStrings.addLibrary)
                }
                .font(.footnote.weight(.semibold))
            }
            .accessibilityIdentifier(AccessibilityID.Settings.addLibraryButton)
            .accessibilityLabel(DisplayStrings.addLibrary)
        }
    }

    private func accountDetail(for account: Account) -> some View {
        AccountDetailView(libraryAccountID: account.uuid, appContainer: .production())
            .navigationBarTitleDisplayMode(.inline)
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
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
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
        if RemoteFeatureFlags.shared.isTriageBotEnabled {
            Section(header: Text("Support")) {
                let chat = TriageBotSupportView()
                let wrapper = chat.anyView()
                row(title: "Get Help", index: 10, selection: self.$selectedView, destination: wrapper)
                    .accessibilityIdentifier("settings.row.getHelp")
                    .accessibilityLabel("Get Help — chat with our support bot")
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

    @ViewBuilder private var developerSettingsSection: some View {
        if AppContainer.production().settings.customMainFeedURL == nil && showDeveloperSettings {
            Section(header: Text(DisplayStrings.developerSettings).accessibilityHidden(true), footer: versionInfo) {
                let viewController = TPPDeveloperSettingsTableViewController()

                let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
                    .navigationBarTitle(Text(DisplayStrings.developerSettings))

                row(title: DisplayStrings.developerSettings, index: 6, selection: self.$selectedView, destination: wrapper.anyView())
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

// MARK: - LibraryRowView

/// One row in the inline MY LIBRARIES section. Renders the library logo,
/// name, optional subtitle, and a checkmark on the active library. Loads
/// the logo lazily through `AccountLogoDelegate` if it isn't already cached.
private struct LibraryRowView: View {
    let account: Account
    let isCurrent: Bool

    @State private var displayLogo: UIImage

    init(account: Account, isCurrent: Bool) {
        self.account = account
        self.isCurrent = isCurrent
        // Prefer the cached logo if present so the cell never renders the
        // placeholder for a library whose real logo is already on disk.
        _displayLogo = State(
            initialValue: account.imageCache.get(for: account.uuid) ?? account.logo
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: 22, height: 22)
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "circle")
                        .resizable()
                        .frame(width: 22, height: 22)
                        .foregroundColor(.secondary.opacity(0.4))
                }
            }
            .frame(width: 28)
            .accessibilityHidden(true)

            Image(uiImage: displayLogo)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .palaceFont(.body)
                    .lineLimit(2)
                if let subtitle = account.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { loadLogoIfNeeded() }
    }

    private var accessibilityLabel: String {
        let prefix = isCurrent ? "\(Strings.Generic.selected). " : ""
        if let subtitle = account.subtitle, !subtitle.isEmpty {
            return "\(prefix)\(account.name). \(subtitle)"
        }
        return "\(prefix)\(account.name)"
    }

    private func loadLogoIfNeeded() {
        if account.imageCache.get(for: account.uuid) != nil { return }
        guard account.logoUrl != nil else { return }
        let proxy = LogoLoadProxy { newLogo in
            // imageCache writes happen inside the Account loader; mirror into
            // local state so the SwiftUI row updates without waiting for the
            // next refresh tick.
            displayLogo = newLogo
        }
        account.logoDelegate = proxy
        // Keep the proxy alive until the load returns by parking it on the
        // account itself — Account holds `logoDelegate` weakly.
        LogoProxyHolder.shared.retain(proxy, for: account.uuid)
        account.loadLogo()
    }
}

/// AccountLogoDelegate forwarder used by `LibraryRowView` because SwiftUI
/// `View` structs can't directly conform to ObjC delegate protocols.
private final class LogoLoadProxy: NSObject, AccountLogoDelegate {
    private let onUpdate: (UIImage) -> Void
    init(onUpdate: @escaping (UIImage) -> Void) {
        self.onUpdate = onUpdate
    }
    func logoDidUpdate(in account: Account, to newLogo: UIImage) {
        DispatchQueue.main.async { [onUpdate] in
            onUpdate(newLogo)
        }
    }
}

/// Account.logoDelegate is held weakly. Park proxies here so a row's
/// in-flight logo load isn't dropped when the proxy goes out of scope.
private final class LogoProxyHolder {
    static let shared = LogoProxyHolder()
    private var proxies: [String: LogoLoadProxy] = [:]
    private let lock = NSLock()

    func retain(_ proxy: LogoLoadProxy, for uuid: String) {
        lock.lock(); defer { lock.unlock() }
        proxies[uuid] = proxy
    }

    func release(_ uuid: String) {
        lock.lock(); defer { lock.unlock() }
        proxies.removeValue(forKey: uuid)
    }
}
