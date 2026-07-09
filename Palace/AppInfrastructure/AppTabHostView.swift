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
    /// Owned once here (NOT created inline in `body`). `MyBooksViewModel.init`
    /// runs `loadData()`/`registerNotifications()` synchronously, so building
    /// it in `tabViewContent` allocated a fresh, self-publishing view-model on
    /// every re-render → "update multiple times per frame" → main-thread freeze.
    @StateObject private var myBooksViewModel: MyBooksViewModel
    /// Module B (swarm_0b7616e7) — single ActiveSessionsViewModel for
    /// the app lifetime. Constructed here (composition root for the
    /// Continue Reading + Continue Listening rows) and threaded into
    /// `CatalogView`. The viewmodel observes `bookRegistry`,
    /// `audiobookSession`, and `.TPPCurrentAccountDidChange` internally,
    /// so it does not need to be re-created across tab switches or
    /// library swaps.
    @StateObject private var activeSessionsViewModel: ActiveSessionsViewModel
    /// Polish-phase (in-app-nav-polish-2026-06-01) reactivity fix:
    /// `AppTabHostView` must observe the presenter directly so SwiftUI
    /// re-evaluates `body` when `isPlayerExpanded` flips (mini-player tap
    /// → expand → fullScreenCover presents). Without this `@ObservedObject`,
    /// the `fullScreenCover(isPresented:)` Binding never sees the change
    /// because the binding's `get` closure reads a value SwiftUI is not
    /// tracking — only the inner `AudiobookMiniPlayerView` (which has its
    /// own `@ObservedObject`) re-renders when the presenter publishes.
    @ObservedObject private var audiobookSessionPresenter: AudiobookSessionPresenter

    /// Drives the app-rating sentiment gate overlay (PP-4089). Process-cached
    /// on the AppContainer so the trigger sites (book completion / borrow) and
    /// this overlay share one instance.
    @ObservedObject private var ratingPromptPresenter: RatingPromptPresenter

    /// Subscribes to the developer-settings local override so the view
    /// re-renders the moment the dev toggle flips. The actual gating
    /// decision delegates to `RemoteFeatureFlags.shared
    /// .isInAppPlaybackNavEnabled`, which combines the override (wins
    /// when set) with the Firebase Remote Config `in_app_playback_nav_enabled`
    /// value (fallback). Reading the @AppStorage value inside
    /// `inAppPlaybackNavEnabled` registers the SwiftUI observation
    /// against the same UserDefaults key the dev toggle writes to.
    @AppStorage("RemoteFeatureFlags.inAppPlaybackNavLocalOverride")
    private var inAppPlaybackNavLocalOverride: Bool = false

    private var inAppPlaybackNavEnabled: Bool {
        _ = inAppPlaybackNavLocalOverride  // trigger SwiftUI observation
        return RemoteFeatureFlags.shared.isInAppPlaybackNavEnabled
    }

    init(appContainer: AppContainer = .production()) {
        self.appContainer = appContainer
        self.bookRegistry = appContainer.bookRegistry
        // Bind the presenter via the property wrapper's projected value so
        // the @ObservedObject reactivity is installed before any body
        // evaluation. The presenter itself is process-cached on the
        // AppContainer so this read returns the same instance the mini-
        // player + manager + CarPlay bridge all use.
        self._audiobookSessionPresenter = ObservedObject(initialValue: appContainer.audiobookSessionPresenter)
        self._ratingPromptPresenter = ObservedObject(initialValue: appContainer.ratingPromptPresenter)
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
            imageCache: appContainer.imageCache,
            // Module D (swarm_495a88d9 / PP-2679): the "Side Loaded" catalog lane.
            // The flag gate lives HERE (not in the VM) — the provider returns []
            // when side-loading is off, so the VM never sees the flag and the lane
            // simply doesn't appear. Read lazily so registry/flag changes take
            // effect on the next catalog conversion.
            sideloadedLaneBooksProvider: {
                RemoteFeatureFlags.shared.isSideLoadingEnabled
                    ? appContainer.sideloadedBookRegistry.allBooks
                    : []
            }
        ))
        _myBooksViewModel = StateObject(wrappedValue: MyBooksViewModel(appContainer: appContainer))
        // Module B (swarm_0b7616e7) composition root for the Continue
        // Reading row's data source. `DefaultRecentlyReadingService` is
        // a pure function of `bookRegistry.myBooks` + saved location, so
        // it carries no extra dependencies and lives as long as the
        // viewmodel does. Initial state seeds synchronously inside the
        // viewmodel `init` so the first CatalogView body sees the rows
        // populated where applicable.
        let recentlyReading = DefaultRecentlyReadingService(
            bookRegistry: appContainer.bookRegistry,
            bookOpenTracker: appContainer.bookOpenTracker
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
    var body: some View {
        ZStack(alignment: .bottom) {
            tabViewContent
            resizingPlayerOverlay
            SentimentGateView(presenter: ratingPromptPresenter)
        }
    }

    /// Compact mini-bar height (points, excluding the safe-area/tab-bar inset
    /// added below it when minimized). The overlay height interpolates between
    /// this and full-screen.
    private static let miniBarHeight: CGFloat = 74
    /// Breathing room between the minimized card and the tab bar.
    private static let miniMargin: CGFloat = 8

    /// Standard `UITabBar` height (points) the minimized card floats above.
    /// The device's variable home-indicator inset is added on top at runtime.
    private static let tabBarHeight: CGFloat = 49

    /// The live bottom safe-area inset (home indicator). Read from the key window
    /// rather than the overlay's `GeometryReader`, because the overlay
    /// `.ignoresSafeArea()`s (so the full player can go edge-to-edge) and inside
    /// that the GR reports a bottom inset of 0 — which put the minimized card
    /// UNDER the tab bar (it overlapped the icons). This reads the real inset so
    /// the mini card floats clear of the tab bar + home indicator.
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    /// The single "resize overlay" — the full player and the mini bar are ONE
    /// bottom-anchored card that RESIZES between full-screen (`isPlayerExpanded`)
    /// and a compact `miniBarHeight` bar (minimized), so it reads as one view
    /// pulled down into a smaller one rather than two views swapping. Replaces
    /// the former `persistentFullPlayerOverlay` (offset slide) + the mini-bar
    /// `safeAreaInset` + the `collapsedPillOverlay` (the pill is gone — the
    /// "collapsed" state is now just the mini SIZE, which also removes the
    /// pill's tap-through bug).
    ///
    /// The toolkit `AudiobookPlayerView` (inside `AudiobookFullPlayerCoverContainer`)
    /// stays MOUNTED at both sizes — it is opacity-crossfaded with the compact
    /// bar, never removed — so playback never unloads (the reason the old design
    /// kept it mounted in a persistent overlay). Only `stopPlayback` (the ✕)
    /// tears it down. In a reader the whole card slides off-screen via `offset`
    /// WITHOUT unmounting, so audio keeps playing with no chrome.
    ///
    /// The existing drags already drive `isPlayerExpanded` — the mini bar's
    /// drawer-drag-up expands, and `AudiobookFullPlayerCoverContainer`'s
    /// swipe-down minimizes — so this overlay only translates that flag into a
    /// height / corner-radius / opacity morph.
    @ViewBuilder
    private var resizingPlayerOverlay: some View {
        if inAppPlaybackNavEnabled, audiobookSessionPresenter.playbackModel != nil {
            ZStack {
                // Hidden toolkit keeper: the toolkit `AudiobookPlayerView` (inside
                // `AudiobookFullPlayerCoverContainer`) stays MOUNTED but invisible
                // and non-interactive, so its playback wiring never tears down
                // (its `onDisappear` fires `stop()`/`unload()`). The CUSTOM
                // `AudiobookMorphingPlayerView` is the visible UI now — it reflows
                // as one view (matchedGeometry cover) between full and mini instead
                // of crossfading the toolkit player with a separate bar. If device
                // testing confirms playback survives without it, this keeper can be
                // removed; kept as the safe default.
                AudiobookFullPlayerCoverContainer(presenter: audiobookSessionPresenter)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                AudiobookMorphingPlayerView(
                    presenter: audiobookSessionPresenter,
                    progress: audiobookSessionPresenter.progress,
                    audiobookSession: appContainer.audiobookSession
                )
            }
        }
    }

    private var tabViewContent: some View {
        TabView(selection: $router.selected) {
            NavigationHostView(rootView: CatalogView(
                viewModel: catalogViewModel,
                activeSessionsViewModel: activeSessionsViewModel,
                appContainer: appContainer
            ))
                .environmentObject(router)
                .tabItem {
                    VStack {
                        Image("Catalog").renderingMode(.template)
                        Text(Strings.Settings.catalog)
                    }
                }
                .tag(AppTab.catalog)
                .accessibilityIdentifier(AccessibilityID.TabBar.catalogTab)

            NavigationHostView(rootView: MyBooksView(model: myBooksViewModel, appContainer: appContainer))
                .tabItem {
                    VStack {
                        Image("MyBooks").renderingMode(.template)
                        Text(Strings.MyBooksView.navTitle)
                    }
                }
                .tag(AppTab.myBooks)
                .accessibilityIdentifier(AccessibilityID.TabBar.myBooksTab)

            NavigationHostView(rootView: HoldsView(appContainer: appContainer))
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
                .tabItem { Label(Strings.Settings.settings, systemImage: "gearshape") }
                .tag(AppTab.settings)
                .accessibilityIdentifier(AccessibilityID.TabBar.settingsTab)
        }
        .tint(Color.accentColor)
        // Polish-phase (in-app-nav-polish-2026-06-01): the full-player
        // is no longer hosted in a fullScreenCover (the cover's dismiss
        // unmounted the toolkit's AudiobookPlayerView, which fires
        // playbackModel.stop() in its onDisappear → unloads the player).
        // It's now rendered in `persistentFullPlayerOverlay` at the
        // ZStack root, animated off-screen on minimize, so its
        // onDisappear never fires and playback survives minimize/expand
        // cycles intact.
        .onAppear {
            appContainer.tabRouterHub.router = router
            appContainer.tabRouterHub.applyPending()
        }
        .onChange(of: router.selected) { _, newTab in
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
    nonisolated static func computeReadyCount(books: [TPPBook]) -> Int {
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

    nonisolated static func computeReservedCount(books: [TPPBook]) -> Int {
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
