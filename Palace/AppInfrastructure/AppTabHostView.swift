import SwiftUI
import UIKit
import PalaceLogging
import PalaceNetwork
import PalaceCatalog

struct AppTabHostView: View {
    // `fileprivate` (not `private`) so the same-file `TabViewChrome` view
    // modifier — which both the iOS 18+ and legacy builders apply — can read
    // the router, container, and tab-bar observer. Still file-scoped.
    @StateObject fileprivate var router = AppTabRouter()
    @State private var holdsBadgeCount: Int = 0
    /// Publishes the live `UITabBar` height so the floating audiobook
    /// mini-player tracks the ACTUAL bar position instead of a hardcoded 49pt
    /// constant — required so the card stays glued to the bar when the iOS 26
    /// minimize-on-scroll behavior makes the bar height dynamic. See
    /// `TabBarModernization.swift`.
    @StateObject fileprivate var tabBarHeightObserver = TabBarHeightObserver()
    fileprivate let appContainer: AppContainer
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
    /// tracking — only the mounted audiobook player view (which has its
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
    /// The custom `AudiobookMorphingPlayerView` is the ONLY player surface now —
    /// it reflows as one view (matchedGeometry cover) between full and mini
    /// instead of crossfading the toolkit player with a separate bar. Playback
    /// is owned by `AudiobookSessionManager`'s `AudiobookManager` and its
    /// model-owned throttled autosave, both independent of any mounted view, so
    /// the card can slide off-screen (reader) or minimize WITHOUT unloading
    /// audio. Only `stopPlayback` (the ✕) tears the session down.
    ///
    /// The former hidden toolkit "keeper" — an `opacity(0)`,
    /// `allowsHitTesting(false)` container wrapping the toolkit
    /// `AudiobookPlayerView`, mounted here solely so its
    /// `setupBackgroundStateHandling()` observers would persist position on
    /// background/terminate — has been removed. That lifecycle persist now
    /// lives in `AudiobookSessionManager.subscribeToAppLifecyclePositionPersistence()`,
    /// the object that actually owns playback.
    ///
    /// The existing drags already drive `isPlayerExpanded` (the mini bar's
    /// drawer-drag-up expands; the full player's swipe-down minimizes) so this
    /// overlay only translates that flag into a height / corner-radius / opacity
    /// morph inside `AudiobookMorphingPlayerView`.
    @ViewBuilder
    private var resizingPlayerOverlay: some View {
        // Mount on `currentBook` (set by `presentLoadingShell` the instant a
        // fresh open begins) OR `playbackModel` (set when the loader binds), so
        // the player slides up immediately with its loading skeleton instead of
        // waiting for the whole load chain. Both are cleared by
        // `clearActiveSession()` on close / error, so the overlay unmounts then.
        if inAppPlaybackNavEnabled,
           audiobookSessionPresenter.playbackModel != nil
            || audiobookSessionPresenter.currentBook != nil {
            AudiobookMorphingPlayerView(
                presenter: audiobookSessionPresenter,
                progress: audiobookSessionPresenter.progress,
                audiobookSession: appContainer.audiobookSession
            )
            // Feed the mini-player the inset derived from the LIVE tab-bar
            // height (measured in `TabBarHeightObserver`) instead of the
            // hardcoded 49pt, so the floating card stays glued to the bar even
            // as the iOS 26 minimize-on-scroll behavior changes the bar height.
            // A `nil` (unmeasured) value leaves the mini-player on its own
            // window-based fallback — identical to the historical behavior.
            .environment(
                \.miniPlayerTabBarInset,
                TabBarModern.miniPlayerBottomInset(
                    safeAreaBottom: bottomSafeInset,
                    tabBarHeight: tabBarHeightObserver.tabBarHeight
                )
            )
        }
    }

    /// Whether the audiobook mini-player overlay is currently mounted (an
    /// active session floats above the tab bar). Mirrors the predicate in
    /// `resizingPlayerOverlay`. Gates the iOS 26 minimize-on-scroll behavior:
    /// we pin the bar while a mini-player is up so it can't minimize out from
    /// under the floating card.
    fileprivate var miniPlayerActive: Bool {
        inAppPlaybackNavEnabled && audiobookSessionPresenter.playbackModel != nil
    }

    /// Whether the iOS 26 minimize-on-scroll behavior should be active. Pinned
    /// (`false`) while a mini-player is up so the bar can't minimize out from
    /// under the floating card. See `TabBarModern.shouldEnableTabBarMinimize`.
    fileprivate var shouldMinimizeTabBar: Bool {
        TabBarModern.shouldEnableTabBarMinimize(miniPlayerActive: miniPlayerActive)
    }

    /// The whole tab host. Picks the typed `Tab(value:role:)` builder on iOS 18+
    /// and the classic `.tabItem` + `.tag` builder below it. Both apply the same
    /// shared chrome (`tabViewChrome`) so there is no drift between the paths.
    @ViewBuilder
    private var tabViewContent: some View {
        // AnyView-erase each branch: the iOS-18 `Tab(value:)` builder and the
        // legacy `.tabItem` builder produce different opaque `some View` types,
        // and materializing a `_ConditionalContent` of an availability-gated
        // opaque type trips the type-checker (surfaces as a misleading
        // `CodingKeyRepresentable` error). Erasing resolves each branch
        // independently. The extra AnyView is inconsequential at the tab-host
        // root (evaluated once per launch).
        if #available(iOS 18, *) {
            AnyView(modernTabView)
        } else {
            AnyView(legacyTabView)
        }
    }

    // MARK: - iOS 18+ typed builder

    @available(iOS 18, *)
    private var modernTabView: some View {
        TabView(selection: $router.selected) {
            Tab(value: AppTab.catalog) {
                catalogRoot
            } label: {
                Self.tabLabel(for: .catalog)
            }
            .accessibilityIdentifier(AccessibilityID.TabBar.catalogTab)

            Tab(value: AppTab.myBooks) {
                myBooksRoot
            } label: {
                Self.tabLabel(for: .myBooks)
            }
            .accessibilityIdentifier(AccessibilityID.TabBar.myBooksTab)

            Tab(value: AppTab.holds) {
                holdsRoot
            } label: {
                Self.tabLabel(for: .holds)
            }
            .badge(holdsBadgeCount)
            .accessibilityIdentifier(AccessibilityID.TabBar.holdsTab)

            Tab(value: AppTab.settings) {
                settingsRoot
            } label: {
                Self.tabLabel(for: .settings)
            }
            .accessibilityIdentifier(AccessibilityID.TabBar.settingsTab)
        }
        .modifier(TabViewChrome(host: self))
    }

    // MARK: - Pre-iOS-18 builder (deployment floor is iOS 17)

    private var legacyTabView: some View {
        TabView(selection: $router.selected) {
            catalogRoot
                .tabItem { Self.tabLabel(for: .catalog) }
                .tag(AppTab.catalog)
                .accessibilityIdentifier(AccessibilityID.TabBar.catalogTab)

            myBooksRoot
                .tabItem { Self.tabLabel(for: .myBooks) }
                .tag(AppTab.myBooks)
                .accessibilityIdentifier(AccessibilityID.TabBar.myBooksTab)

            holdsRoot
                .tabItem { Self.tabLabel(for: .holds) }
                .badge(holdsBadgeCount)
                .tag(AppTab.holds)
                .accessibilityIdentifier(AccessibilityID.TabBar.holdsTab)

            settingsRoot
                .tabItem { Self.tabLabel(for: .settings) }
                .tag(AppTab.settings)
                .accessibilityIdentifier(AccessibilityID.TabBar.settingsTab)
        }
        .modifier(TabViewChrome(host: self))
    }

    // MARK: - Shared tab roots (one source of truth for both builders)

    private var catalogRoot: some View {
        NavigationHostView(rootView: CatalogView(
            viewModel: catalogViewModel,
            activeSessionsViewModel: activeSessionsViewModel,
            appContainer: appContainer
        ))
        .environmentObject(router)
    }

    private var myBooksRoot: some View {
        NavigationHostView(rootView: MyBooksView(model: myBooksViewModel, appContainer: appContainer))
    }

    private var holdsRoot: some View {
        NavigationHostView(rootView: HoldsView(appContainer: appContainer))
    }

    private var settingsRoot: some View {
        NavigationHostView(rootView: TPPSettingsView())
    }

    /// The one label idiom shared by both builders. Settings uses the SF Symbol
    /// `gearshape`; the other three use their raster PNG assets rendered as
    /// template images so the tint tints them. Icons/order/direction unchanged.
    @ViewBuilder
    static func tabLabel(for tab: AppTab) -> some View {
        switch tab {
        case .catalog:
            Label { Text(Strings.Settings.catalog) } icon: {
                Image("Catalog").renderingMode(.template)
            }
        case .myBooks:
            Label { Text(Strings.MyBooksView.navTitle) } icon: {
                Image("MyBooks").renderingMode(.template)
            }
        case .holds:
            Label { Text(Strings.HoldsView.reservations) } icon: {
                Image("Holds").renderingMode(.template)
            }
        case .settings:
            Label(Strings.Settings.settings, systemImage: "gearshape")
        default:
            EmptyView()
        }
    }

    // MARK: - Shared side effects

    /// Runs on tab selection change: pop-to-root, dismiss top VC, sync, announce.
    /// Extracted so the iOS 18+ and legacy builders share one implementation.
    func handleTabSelectionChange(to newTab: AppTab) {
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
}

/// The shared chrome applied to BOTH the iOS 18+ typed `Tab` builder and the
/// pre-18 `.tabItem` builder — brand tint, selection haptic, tab-bar material,
/// the iOS 26 Liquid-Glass minimize behavior, plus the lifecycle/selection/
/// badge side effects. Factored into one `ViewModifier` so the two builders
/// can never drift.
private struct TabViewChrome: ViewModifier {
    let host: AppTabHostView

    func body(content: Content) -> some View {
        content
            // Monochrome selected tab: `.primary` (the label color) rather than
            // a color accent, so the selected tab reads black in light / white
            // in dark and the bar stays neutral — no blue. (For reference: the
            // default `Color.accentColor` here resolved to the SYSTEM blue,
            // since the app ships no AccentColor asset; a neutral tint is the
            // intended look per product.)
            .tint(.primary)
            // Selection haptic (iOS 17+ `.sensoryFeedback` under the hood).
            // `palaceHaptic` is preference- AND Reduce-Motion-gated, so it
            // no-ops when the patron has haptics off or Reduce Motion on.
            .palaceHaptic(.selection, trigger: host.router.selected)
            // Idiomatic tab-bar background. On iOS 26 the Liquid-Glass system
            // material owns the bar chrome, so we DON'T force a material there
            // (forcing one fights the glass + the minimize animation). Below
            // 26, make the standard system-material bar background explicit.
            .modifier(TabBarBackgroundModifier())
            .modifier(TabBarMinimizeModifier(enabled: host.shouldMinimizeTabBar))
            // Polish-phase (in-app-nav-polish-2026-06-01): the full-player
            // is no longer hosted in a fullScreenCover; it's rendered in the
            // resizing overlay at the ZStack root so playback survives
            // minimize/expand cycles intact.
            .onAppear {
                host.appContainer.tabRouterHub.router = host.router
                host.appContainer.tabRouterHub.applyPending()
                host.tabBarHeightObserver.measure()
            }
            .onChange(of: host.router.selected) { _, newTab in
                host.handleTabSelectionChange(to: newTab)
                // Re-measure: selecting a tab can change bar chrome/height
                // (esp. under iOS 26 minimize), keeping the mini-player glued.
                host.tabBarHeightObserver.measure()
            }
            .onAppear {
                host.updateHoldsBadge()
            }
            .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryStateDidChange)) { _ in
                host.updateHoldsBadge()
            }
    }
}

/// Availability-gated tab-bar background. iOS 26's Liquid Glass owns the bar
/// background, so we only make the system material explicit on 18–25.
private struct TabBarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // Liquid Glass provides the bar material; don't override it.
            content
        } else {
            content
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(Material.bar, for: .tabBar)
        }
    }
}

/// Availability-gated iOS 26 Liquid-Glass minimize-on-scroll behavior. The
/// `enabled` flag is the conditional gate: it is `false` while an audiobook
/// mini-player is active so the bar can't minimize out from under the floating
/// card (see `TabBarModern.shouldEnableTabBarMinimize`).
private struct TabBarMinimizeModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
        } else {
            content
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

fileprivate extension AppTabHostView {
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
