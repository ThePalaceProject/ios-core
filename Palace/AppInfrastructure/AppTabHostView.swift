import SwiftUI
import UIKit
import PalaceLogging
import PalaceNetwork

struct AppTabHostView: View {
    @StateObject private var router = AppTabRouter()
    @State private var holdsBadgeCount: Int = 0
    private let appContainer: AppContainer
    let bookRegistry: TPPBookRegistryProvider
    @StateObject private var catalogViewModel: CatalogViewModel

    init(appContainer: AppContainer = .production()) {
        self.appContainer = appContainer
        self.bookRegistry = appContainer.bookRegistry
        let client = URLSessionNetworkClient()
        let parser = OPDSParser()
        let api = DefaultCatalogAPI(client: client, parser: parser)
        let repository = CatalogRepository(api: api)
        _catalogViewModel = StateObject(wrappedValue: CatalogViewModel(
            repository: repository,
            topLevelURLProvider: { appContainer.settings.accountMainFeedURL },
            bookRegistry: appContainer.bookRegistry,
            imageCache: appContainer.imageCache
        ))
    }

    var body: some View {
        TabView(selection: $router.selected) {
            NavigationHostView(rootView: CatalogView(viewModel: catalogViewModel))
                .environmentObject(router)
                .tabItem {
                    VStack {
                        Image("Catalog").renderingMode(.template)
                        Text(Strings.Settings.catalog)
                    }
                }
                .tag(AppTab.catalog)
                .accessibilityIdentifier(AccessibilityID.TabBar.catalogTab)

            NavigationHostView(rootView: MyBooksView(model: MyBooksViewModel(appContainer: appContainer), appContainer: appContainer))
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
        guard bookRegistry.state == .loaded || bookRegistry.state == .synced else {
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

            var readyCount = 0

            for book in held {
                book.defaultAcquisition?.availability.match(unavailable: nil,
                                                                       limited: nil,
                                                                       unlimited: nil,
                                                                       reserved: nil,
                                                                       ready: { _ in readyCount += 1 })
            }

            #if DEBUG
            if debugSettings.isBadgeLoggingEnabled {
                var reservedCount = 0
                for book in held {
                    book.defaultAcquisition?.availability.match(unavailable: nil, limited: nil, unlimited: nil,
                                                                           reserved: { _ in reservedCount += 1 }, ready: nil)
                }
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
