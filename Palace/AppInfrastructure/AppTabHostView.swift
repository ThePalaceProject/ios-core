import SwiftUI
import UIKit
import PalaceLogging
import PalaceNetwork
import PalaceCatalog

struct AppTabHostView: View {
    @StateObject private var router = AppTabRouter()
    @State private var holdsBadgeCount: Int = 0
    private let appContainer: AppContainer
    let bookRegistry: TPPBookRegistryProvider
    @StateObject private var catalogViewModel: CatalogViewModel
    /// Module B (swarm_0b7616e7) — single ActiveSessionsViewModel for
    /// the app lifetime. Constructed here (composition root for the
    /// Continue Reading + Continue Listening rows) and threaded into
    /// `CatalogView`. The viewmodel observes `bookRegistry`,
    /// `audiobookSession`, and `.TPPCurrentAccountDidChange` internally,
    /// so it does not need to be re-created across tab switches or
    /// library swaps.
    @StateObject private var activeSessionsViewModel: ActiveSessionsViewModel

    init(appContainer: AppContainer = .production()) {
        self.appContainer = appContainer
        self.bookRegistry = appContainer.bookRegistry
        let client = URLSessionNetworkClient()
        let parser = OPDSParser()
        let api = DefaultCatalogAPI(client: client, parser: parser, featureFlags: RemoteFeatureFlags.shared)
        // Cache isolation: scope by the *current* account UUID so a single
        // repository instance can never serve library A's catalog to
        // library B if it somehow survives a library switch. The closure
        // is re-read on every cache-key derivation, so account changes
        // take effect immediately. See `CatalogRepository.cacheKey(for:)`.
        let accountsManager = appContainer.accountsManager
        let repository = CatalogRepository(
            api: api,
            accountID: { [weak accountsManager] in accountsManager?.currentAccount?.uuid }
        )
        _catalogViewModel = StateObject(wrappedValue: CatalogViewModel(
            repository: repository,
            topLevelURLProvider: { appContainer.settings.accountMainFeedURL },
            bookRegistry: appContainer.bookRegistry,
            imageCache: appContainer.imageCache
        ))
        // Module B (swarm_0b7616e7) composition root for the Continue
        // Reading row's data source. `DefaultRecentlyReadingService` is
        // a pure function of `bookRegistry.myBooks` + saved location, so
        // it carries no extra dependencies and lives as long as the
        // viewmodel does. Initial state seeds synchronously inside the
        // viewmodel `init` so the first CatalogView body sees the rows
        // populated where applicable.
        let recentlyReading = DefaultRecentlyReadingService(
            bookRegistry: appContainer.bookRegistry
        )
        _activeSessionsViewModel = StateObject(wrappedValue: ActiveSessionsViewModel(
            recentlyReadingService: recentlyReading,
            audiobookSession: appContainer.audiobookSession
        ))
    }

    // Mini-player inset modifier. Applied to each tab's NavigationHostView
    // rather than the TabView root because `.safeAreaInset(.bottom)` on a
    // TabView intercepts taps on the system tab bar on pre-iOS-18 SwiftUI
    // (the inset region renders above the tab bar but extends the touch
    // area to cover it). Per-tab application keeps the mini-player ABOVE
    // each tab's nav-stack content and BELOW the system tab bar, which is
    // the standard Apple Music / Audible layout.
    //
    // All 4 inset instances observe the same presenter, so the mini-player
    // chrome renders consistently across tabs and reflects the single
    // source of truth.
    @ViewBuilder
    private func miniPlayerInset() -> some View {
        AudiobookMiniPlayerView(
            presenter: appContainer.audiobookSessionPresenter,
            audiobookSession: appContainer.audiobookSession
        )
    }

    var body: some View {
        TabView(selection: $router.selected) {
            NavigationHostView(rootView: CatalogView(
                viewModel: catalogViewModel,
                activeSessionsViewModel: activeSessionsViewModel,
                appContainer: appContainer
            ))
                .environmentObject(router)
                .safeAreaInset(edge: .bottom, content: miniPlayerInset)
                .tabItem {
                    VStack {
                        Image("Catalog").renderingMode(.template)
                        Text(Strings.Settings.catalog)
                    }
                }
                .tag(AppTab.catalog)
                .accessibilityIdentifier(AccessibilityID.TabBar.catalogTab)

            NavigationHostView(rootView: MyBooksView(model: MyBooksViewModel(appContainer: appContainer), appContainer: appContainer))
                .safeAreaInset(edge: .bottom, content: miniPlayerInset)
                .tabItem {
                    VStack {
                        Image("MyBooks").renderingMode(.template)
                        Text(Strings.MyBooksView.navTitle)
                    }
                }
                .tag(AppTab.myBooks)
                .accessibilityIdentifier(AccessibilityID.TabBar.myBooksTab)

            NavigationHostView(rootView: HoldsView(appContainer: appContainer))
                .safeAreaInset(edge: .bottom, content: miniPlayerInset)
                .tabItem {
                    VStack {
                        Image("Holds").renderingMode(.template)
                        Text(Strings.HoldsView.reservations)
                    }
                }
                .badge(holdsBadgeCount)
                .tag(AppTab.holds)
                .accessibilityIdentifier(AccessibilityID.TabBar.holdsTab)

            NavigationHostView(rootView: TPPSettingsView())
                .safeAreaInset(edge: .bottom, content: miniPlayerInset)
                .tabItem { Label(Strings.Settings.settings, systemImage: "gearshape") }
                .tag(AppTab.settings)
                .accessibilityIdentifier(AccessibilityID.TabBar.settingsTab)
        }
        .tint(Color.accentColor)
        .fullScreenCover(isPresented: Binding(
            // Module D (swarm_0b7616e7) — root-level full-player presentation.
            // Binds the SwiftUI `isPresented` to the presenter's
            // `isPlayerExpanded` @Published value so:
            //   - tap on mini-player → `presenter.expand()` flips to true → cover shows
            //   - swipe-down inside the cover → `presenter.minimize()` flips to false → cover dismisses
            //   - `presenter.presentOnFirstOpen()` (called during F-011) flips true synchronously
            //     before the readiness gate → cover-art lockup visible during load
            get: { appContainer.audiobookSessionPresenter.isPlayerExpanded },
            set: { appContainer.audiobookSessionPresenter.isPlayerExpanded = $0 }
        )) {
            AudiobookFullPlayerCoverContainer(
                presenter: appContainer.audiobookSessionPresenter
            )
        }
        .onAppear {
            appContainer.tabRouterHub.router = router
            appContainer.tabRouterHub.applyPending()
        }
        .onChange(of: router.selected) { newTab in
            // Respect reduce motion accessibility setting
            if UIAccessibility.isReduceMotionEnabled {
                appContainer.navigationCoordinatorHub.coordinator?.popToRoot()
            } else {
                withAnimation(.easeInOut) {
                    appContainer.navigationCoordinatorHub.coordinator?.popToRoot()
                }
            }
            if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate,
               let top = appDelegate.topViewController() {
                top.dismiss(animated: true)
            }
            NotificationCenter.default.post(name: .AppTabSelectionDidChange, object: nil)
            // F-035: Auto-refresh My Books and Holds when their tabs
            // become visible so the user doesn't have to pull-to-refresh
            // to see newly borrowed/returned/held books.
            if newTab == .myBooks || newTab == .holds {
                appContainer.bookRegistry.sync()
            }
            // Announce the new tab for VoiceOver when tab changes
            if UIAccessibility.isVoiceOverRunning {
                let message = Self.accessibilityLabel(for: newTab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
        }
        .onAppear {
            updateHoldsBadge()
        }
        .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryStateDidChange)) { _ in
            updateHoldsBadge()
        }
    }
}

extension AppTabHostView {
    /// Pure helpers extracted for unit testability — these were previously
    /// inline closures inside `updateHoldsBadge()` that could not be exercised
    /// by tests, leaving mutations like `+= 1` → `-= 1` undetected.
    static func computeReadyCount(books: [TPPBook]) -> Int {
        var count = 0
        for book in books {
            book.defaultAcquisition?.availability.match(
                unavailable: nil,
                limited: nil,
                unlimited: nil,
                reserved: nil,
                ready: { _ in count += 1 }
            )
        }
        return count
    }

    static func computeReservedCount(books: [TPPBook]) -> Int {
        var count = 0
        for book in books {
            book.defaultAcquisition?.availability.match(
                unavailable: nil,
                limited: nil,
                unlimited: nil,
                reserved: { _ in count += 1 },
                ready: nil
            )
        }
        return count
    }

    /// `state == .loaded || state == .synced` factored out of `updateHoldsBadge`
    /// so the OR/equality conditions can be exercised by tests directly.
    static func shouldUpdateBadge(for state: TPPBookRegistry.RegistryState) -> Bool {
        return state == .loaded || state == .synced
    }
}

private extension AppTabHostView {
    /// VoiceOver announcement label for each tab (matches tab item text).
    static func accessibilityLabel(for tab: AppTab) -> String {
        switch tab {
        case .catalog: return Strings.Settings.catalog
        case .myBooks: return Strings.MyBooksView.navTitle
        case .holds: return Strings.HoldsView.reservations
        case .settings: return Strings.Settings.settings
        default: return ""
        }
    }

    func updateHoldsBadge() {
        guard Self.shouldUpdateBadge(for: bookRegistry.state) else {
            return
        }

        let debugSettings = appContainer.debugSettings

        // Move heavy registry access off main thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            // Use test books if debug configuration is enabled, otherwise use real registry data
            #if DEBUG
            let held: [TPPBook] = debugSettings.createTestHoldBooks() ?? bookRegistry.heldBooks
            let usingTestBooks = debugSettings.isTestHoldsEnabled
            #else
            let held = bookRegistry.heldBooks
            #endif

            let readyCount = Self.computeReadyCount(books: held)

            #if DEBUG
            if debugSettings.isBadgeLoggingEnabled {
                let reservedCount = Self.computeReservedCount(books: held)
                Log.info(#file, "[DEBUG-BADGE] updateHoldsBadge: source=\(usingTestBooks ? "TEST BOOKS" : "registry"), totalHeld=\(held.count), reserved=\(reservedCount), ready=\(readyCount)")
                for (index, book) in held.enumerated() {
                    var status = "unknown"
                    book.defaultAcquisition?.availability.match(unavailable: 
                        { _ in status = "unavailable" },
                        limited: { _ in status = "limited" },
                        unlimited: { _ in status = "unlimited" },
                        reserved: { r in status = "reserved (pos: \(r.holdPosition))" },
                        ready: { _ in status = "READY" }
                    )
                    Log.info(#file, "[DEBUG-BADGE]   Book[\(index)]: '\(book.title)' - status: \(status)")
                }
            }
            #endif

            // Update UI on main thread
            DispatchQueue.main.async {
                self.holdsBadgeCount = readyCount
                UIApplication.shared.applicationIconBadgeNumber = readyCount
            }
        }
    }
}

extension Notification.Name {
    static let AppTabSelectionDidChange = Notification.Name("AppTabSelectionDidChange")
}
