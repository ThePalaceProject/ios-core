import SwiftUI
import UIKit

struct AppTabHostView: View {
    @Environment(\.appContainer) private var container
    @StateObject private var router = AppTabRouter()
    @State private var holdsBadgeCount: Int = 0

    @StateObject private var catalogViewModel: CatalogViewModel = {
        let client = URLSessionNetworkClient()
        let parser = OPDSParser()
        let api = DefaultCatalogAPI(client: client, parser: parser)
        let repository = CatalogRepository(api: api)
        return CatalogViewModel(repository: repository) {
            TPPSettings.shared.accountMainFeedURL
        }
    }()

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

            NavigationHostView(rootView: MyBooksView(model: MyBooksViewModel(
                bookRegistry: container.bookRegistry,
                accountsManager: container.accountsManager,
                settings: container.settings
            )))
                .tabItem {
                    VStack {
                        Image("MyBooks").renderingMode(.template)
                        Text(Strings.MyBooksView.navTitle)
                    }
                }
                .tag(AppTab.myBooks)
                .accessibilityIdentifier(AccessibilityID.TabBar.myBooksTab)

            NavigationHostView(rootView: HoldsView(viewModel: HoldsViewModel(
                bookRegistry: container.bookRegistry,
                accountsManager: container.accountsManager,
                settings: container.settings
            )))
                .tabItem {
                    VStack {
                        Image("Holds").renderingMode(.template)
                        Text(Strings.HoldsView.reservations)
                    }
                }
                .badge(holdsBadgeCount)
                .tag(AppTab.holds)
                .accessibilityIdentifier(AccessibilityID.TabBar.holdsTab)

            // MARK: - Feature-flagged tabs

            // Prototype tabs — not compiled
            // if DiscoveryTab.isEnabled { discoverTab }
            // if StatsTab.isEnabled { statsTab }
            // if CollectionsTab.isEnabled { collectionsTab }

            NavigationHostView(rootView: TPPSettingsView(viewModel: SettingsViewModel(
                settings: container.settings,
                accountsManager: container.accountsManager
            )))
                .tabItem { Label(Strings.Settings.settings, systemImage: "gearshape") }
                .tag(AppTab.settings)
                .accessibilityIdentifier(AccessibilityID.TabBar.settingsTab)
        }
        .tint(Color.accentColor)
        .onAppear { AppTabRouterHub.shared.router = router }
        .onChange(of: router.selected) { _ in
            // Respect reduce motion accessibility setting
            if UIAccessibility.isReduceMotionEnabled {
                NavigationCoordinatorHub.shared.coordinator?.popToRoot()
            } else {
                withAnimation(.easeInOut) {
                    NavigationCoordinatorHub.shared.coordinator?.popToRoot()
                }
            }
            if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate,
               let top = appDelegate.topViewController() {
                top.dismiss(animated: true)
            }
            NotificationCenter.default.post(name: .AppTabSelectionDidChange, object: nil)
        }
        .onAppear {
            updateHoldsBadge()
        }
        .onReceive(TPPBookRegistry.shared.bookStatePublisher.map { _ in () }
            .merge(with: TPPBookRegistry.shared.syncStatePublisher.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        ) { _ in
            updateHoldsBadge()
        }
    }
}

private extension AppTabHostView {

    // MARK: - Feature-flagged tab views

    // Prototype tab views — uncomment when compiled
    // var discoverTab: some View { ... }
    // var statsTab: some View { ... }
    // var collectionsTab: some View { ... }

    // MARK: - Badge

    func updateHoldsBadge() {
        guard TPPBookRegistry.shared.state == .loaded || TPPBookRegistry.shared.state == .synced else {
            return
        }

        // Move heavy registry access off main thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            // Use test books if debug configuration is enabled, otherwise use real registry data
            #if DEBUG
            let held: [TPPBook] = DebugSettings.shared.createTestHoldBooks() ?? TPPBookRegistry.shared.heldBooks
            let usingTestBooks = DebugSettings.shared.isTestHoldsEnabled
            #else
            let held = TPPBookRegistry.shared.heldBooks
            #endif

            var readyCount = 0

            for book in held {
                book.defaultAcquisition?.availability.matchUnavailable(nil,
                                                                       limited: nil,
                                                                       unlimited: nil,
                                                                       reserved: nil,
                                                                       ready: { _ in readyCount += 1 })
            }

            #if DEBUG
            if DebugSettings.shared.isBadgeLoggingEnabled {
                var reservedCount = 0
                for book in held {
                    book.defaultAcquisition?.availability.matchUnavailable(nil, limited: nil, unlimited: nil,
                                                                           reserved: { _ in reservedCount += 1 }, ready: nil)
                }
                Log.info(#file, "[DEBUG-BADGE] updateHoldsBadge: source=\(usingTestBooks ? "TEST BOOKS" : "registry"), totalHeld=\(held.count), reserved=\(reservedCount), ready=\(readyCount)")
                for (index, book) in held.enumerated() {
                    var status = "unknown"
                    book.defaultAcquisition?.availability.matchUnavailable(
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
