//
//  LibrariesView.swift
//  Palace
//
//  The Libraries screen (PP-5098), pushed from a row on Settings so that tab
//  stays short for patrons with many libraries. Hosts `LibrariesSectionViewModel`
//  for switching, adding, and removing libraries.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit
import PalaceUtilities

// MARK: - LibrariesView

struct LibrariesView: View {
    typealias DisplayStrings = Strings.Settings

    @StateObject private var viewModel: LibrariesSectionViewModel
    @State private var switchPromptAccount: Account? = nil

    /// Injected by the caller (from `@Environment(\.appContainer)`). The
    /// container rather than a view model, because a caller-owned view model
    /// would be a `@StateObject` on `TPPSettingsView`, whose `init` cannot read
    /// `@Environment`. `StateObject(wrappedValue:)` takes an autoclosure, so the
    /// view model is built once per view identity.
    private let appContainer: AppContainer

    init(appContainer: AppContainer) {
        self.appContainer = appContainer
        let environment = ProductionLibrariesSectionEnvironment(
            accountsManager: appContainer.accountsManager,
            settings: appContainer.settings
        )
        _viewModel = StateObject(wrappedValue: LibrariesSectionViewModel(environment: environment))
    }

    var body: some View {
        // The overlay composes with this screen's content, not the navigation
        // root, which would render behind a pushed screen. See
        // `SwitchingOverlayContainer`.
        SwitchingOverlayContainer(isSwitching: viewModel.isSwitching) {
            listView
        }
        .navigationBarTitle(DisplayStrings.libraries)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var listView: some View {
        List {
            // During the launch-hydration window the persisted-account lookup
            // can resolve empty before the full catalog materializes; show a
            // skeleton instead of a blank list that pops in.
            if viewModel.isLoading || DebugSettings.forceSkeletons {
                SettingsLibrariesSkeletonView()
                    .transition(.opacity)
            } else {
                librariesSection
                    .transition(.opacity)
            }
        }
        .listStyle(GroupedListStyle())
        .accessibilityIdentifier(AccessibilityID.Libraries.list)
        .accessibleAnimation(PalaceMotion.gentle, value: viewModel.isLoading)
        .onAppear {
            viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)) { _ in
            viewModel.refresh()
        }
        .sheet(isPresented: $viewModel.showAddLibrarySheet) {
            UIViewControllerWrapper(
                TPPAccountList { account in
                    DispatchQueue.main.async {
                        // Adding a library goes through the same switch chain
                        // as the selection control: dismiss the picker, show
                        // the loading overlay while the auth doc loads, then
                        // jump to the Catalog tab so the patron lands in the
                        // new library instead of being parked here.
                        viewModel.showAddLibrarySheet = false
                        viewModel.switchToAccount(account) {
                            appContainer.navigateToTabRoot(.catalog)
                        }
                    }
                },
                updater: { _ in }
            )
        }
    }

    @ViewBuilder private var librariesSection: some View {
        Section(header: librariesSectionHeader) {
            ForEach(viewModel.accounts, id: \.uuid) { account in
                libraryRow(for: account)
                    .accessibilityIdentifier("\(AccessibilityID.Libraries.row).\(account.uuid)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if presentation(for: account).allowsDelete {
                            Button(role: .destructive) {
                                viewModel.deleteSecondary(account)
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
        // Animate add/delete of libraries (list identity keyed on the account
        // uuids) and fire a success haptic when the current library switches
        // (the checkmark moves to the newly-active row).
        .accessibleAnimation(PalaceMotion.standard, value: viewModel.accounts.map(\.uuid))
        .palaceHaptic(.success, trigger: viewModel.currentAccountUUID)
        .confirmationDialog(
            switchPromptTitle,
            isPresented: Binding(
                get: { switchPromptAccount != nil },
                set: { isPresented in if !isPresented { switchPromptAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            // Yes → switch + jump to the Catalog tab. The loading overlay stays
            // up while the auth doc loads; the tab jump is timed to the
            // completion so the catalog opens with data already populated.
            Button(Strings.Generic.yes) {
                if let account = switchPromptAccount {
                    viewModel.switchToAccount(account) {
                        appContainer.navigateToTabRoot(.catalog)
                    }
                }
                switchPromptAccount = nil
            }
            // Destructive role gives the iOS-standard red "No" used in the
            // prototype to distinguish it from the neutral "Cancel".
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

    @ViewBuilder private var librariesSectionHeader: some View {
        HStack {
            Text(DisplayStrings.myLibraries)
            Spacer()
            Button {
                viewModel.presentAddLibrary()
            } label: {
                // Match the surrounding section-header text style so the button
                // reads as part of the header rather than an oversized
                // affordance: footnote weight, tight + icon.
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Text(DisplayStrings.addLibrary)
                }
                .font(.footnote.weight(.semibold))
            }
            .accessibilityIdentifier(AccessibilityID.Libraries.addLibraryButton)
            .accessibilityLabel(DisplayStrings.addLibrary)
        }
    }

    private func presentation(for account: Account) -> LibraryRowPresentation {
        LibraryRowPresentation(
            libraryName: account.name,
            subtitle: account.subtitle,
            isCurrentLibrary: account.uuid == viewModel.currentAccountUUID
        )
    }

    /// One library row: the selection control (switch) and the row body
    /// (library settings) are separate tap targets, so they are separate
    /// views — a `Button` beside a `NavigationLink`, not a control nested
    /// inside a link, which the link would swallow.
    @ViewBuilder private func libraryRow(for account: Account) -> some View {
        let model = presentation(for: account)
        HStack(spacing: 0) {
            selectionControl(for: account, model: model)
            // `.openLibraryDetails` on every row — the table's rowBody column
            // has no other value, so the link is unconditional.
            if model.outcome(of: .rowBody) == .openLibraryDetails {
                NavigationLink(destination: accountDetail(for: account)) {
                    LibraryRowContentView(account: account, model: model)
                }
            }
        }
    }

    @ViewBuilder private func selectionControl(for account: Account, model: LibraryRowPresentation) -> some View {
        // The 22pt glyph sits in a 44pt frame so the tap target meets the
        // WCAG 2.1 AA / HIG minimum without enlarging the drawn control.
        // accesslint:disable A11Y.SWIFTUI.IMAGE_DECORATIVE - labelled on the enclosing SwiftUI.Group via `.accessibilityLabel(model.selectionAccessibilityLabel)`, which sits outside the detector's scan window after the `Image(`
        let glyph = Image(systemName: model.selectionSymbolName)
            .resizable()
            .frame(width: 22, height: 22)
            .foregroundStyle(model.isCurrentLibrary ? Color.green : Color.secondary.opacity(0.4))
            .contentTransition(.symbolEffect(.replace))
            .accessibleAnimation(PalaceMotion.standard, value: model.isCurrentLibrary)
            .frame(width: 44, height: 44)
            // accesslint:enable A11Y.SWIFTUI.IMAGE_DECORATIVE

        // `SwiftUI.Group` qualified: `MyBooksViewModel` declares a module-level
        // `enum Group`, which otherwise shadows it here.
        SwiftUI.Group {
            if model.isSelectionActionable {
                Button {
                    // Routed through the table so the view cannot drift from
                    // the tested contract.
                    if model.outcome(of: .selectionControl) == .confirmSwitch {
                        switchPromptAccount = account
                    }
                } label: {
                    glyph
                }
                // Borderless keeps this control independently hit-tested inside
                // a List row that also contains a NavigationLink.
                .buttonStyle(.borderless)
            } else {
                // Not a button: the active library's control has no action, so
                // VoiceOver must not offer one. It still reports the state.
                glyph
            }
        }
        .accessibilityIdentifier("\(AccessibilityID.Libraries.selectionControl).\(account.uuid)")
        .accessibilityLabel(model.selectionAccessibilityLabel)
    }

    private func accountDetail(for account: Account) -> some View {
        AccountDetailView(libraryAccountID: account.uuid, appContainer: appContainer)
            .navigationBarTitleDisplayMode(.inline)
    }

}

// MARK: - SwitchingOverlayContainer

/// Composes a screen's content with the library-switch loading overlay on top
/// of it.
///
/// A named container so the screen that starts a switch owns the overlay. A
/// `ZStack` sibling of a navigation stack's root renders behind whatever is
/// pushed onto it (PP-5098).
///
/// The stacking is not unit-tested: reading accessibility labels back from a
/// `UIHostingController` returns nothing on the CI simulator, and SwiftUI layers
/// carry no per-layer label for hit-testing. The flag it reads is pinned in
/// `LibrariesSectionViewModelTests`.
struct SwitchingOverlayContainer<Content: View>: View {
    let isSwitching: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()

            // Keep this last in the ZStack so it draws in front of the content;
            // the ordering is not covered by tests.
            //
            // Stays up while the auth document loads — when the view model
            // fires its completion the overlay dismisses and the tab jumps to
            // Catalog in the same beat, so the patron lands on data that has
            // started populating instead of a stale-then-refreshing catalog.
            if isSwitching {
                LibrarySwitchingOverlayView()
                    .transition(.opacity)
            }
        }
        .accessibleAnimation(.easeInOut(duration: 0.2), value: isSwitching)
    }
}

/// The dimmed spinner shown while the active library is switching.
private struct LibrarySwitchingOverlayView: View {
    typealias DisplayStrings = Strings.Settings

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(DisplayStrings.switchingLibrary)
                    .palaceFont(.body)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.6))
            )
        }
        .accessibilityElement(children: .combine)
        // Modal so VoiceOver cannot swipe into the list underneath while the
        // switch is in flight.
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(DisplayStrings.switchingLibrary)
    }
}

// MARK: - LibraryRowContentView

/// The navigable body of a library row: logo, name, and description. Loads the
/// logo lazily through `AccountLogoDelegate` if it isn't already cached.
///
/// The name and description have no `lineLimit`: PP-5098 requires library names
/// to reflow rather than truncate at large Dynamic Type sizes, so they wrap to
/// as many lines as they need (`fixedSize` vertical stops the row from
/// compressing them back down).
private struct LibraryRowContentView: View {
    let account: Account
    let model: LibraryRowPresentation

    @State private var displayLogo: UIImage

    init(account: Account, model: LibraryRowPresentation) {
        self.account = account
        self.model = model
        // Prefer the cached logo if present so the cell never renders the
        // placeholder for a library whose real logo is already on disk.
        _displayLogo = State(
            initialValue: account.imageCache.get(for: account.uuid) ?? account.logo
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: displayLogo)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.libraryName)
                    .palaceFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.rowAccessibilityLabel)
        .onAppear { loadLogoIfNeeded() }
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
        // holder — Account holds `logoDelegate` weakly.
        LogoProxyHolder.shared.retain(proxy, for: account.uuid)
        account.loadLogo()
    }
}

/// AccountLogoDelegate forwarder used by `LibraryRowContentView` because
/// SwiftUI `View` structs can't directly conform to ObjC delegate protocols.
@MainActor
private final class LogoLoadProxy: NSObject, @preconcurrency AccountLogoDelegate {
    private let onUpdate: (UIImage) -> Void
    init(onUpdate: @escaping (UIImage) -> Void) {
        self.onUpdate = onUpdate
    }
    // `Account` invokes this on the main thread (its logo fetch delivers via
    // `DispatchQueue.main.async`), so the forwarding runs on the main actor
    // without an extra hop.
    func logoDidUpdate(in account: Account, to newLogo: UIImage) {
        onUpdate(newLogo)
    }
}

/// Account.logoDelegate is held weakly. Park proxies here so a row's in-flight
/// logo load isn't dropped when the proxy goes out of scope. Lock-backed holder
/// — `@unchecked Sendable` because all access to `proxies` is serialized
/// through `lock`.
private final class LogoProxyHolder: @unchecked Sendable {
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
