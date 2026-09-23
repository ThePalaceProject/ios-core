import SwiftUI

enum AppTab: Hashable {
    case catalog
    case myBooks
    case holds
    case discover
    case stats
    case collections
    case settings
}

@MainActor
final class AppTabRouter: ObservableObject {
    @Published var selected: AppTab = .catalog
}

final class AppTabRouterHub {
    init() {}
    weak var router: AppTabRouter?

    /// Pending tab selection that survives router deallocation.
    /// When the app is backgrounded, SwiftUI may release the view hierarchy
    /// and the weak router reference goes nil. Pending navigation is applied
    /// when AppTabHostView reappears and re-registers the router.
    private var pendingTab: AppTab?

    @MainActor
    func navigate(to tab: AppTab) {
        if let router {
            router.selected = tab
        } else {
            pendingTab = tab
        }
    }

    /// The tab currently on screen, as far as anything outside the view layer can
    /// know it. Prefers the live router; falls back to a pending selection so a
    /// deep link that arrived while the view hierarchy was released still resolves
    /// to the tab the patron is about to land on rather than the stale default.
    @MainActor
    var currentTab: AppTab? {
        router?.selected ?? pendingTab
    }

    @MainActor
    func applyPending() {
        guard let tab = pendingTab, let router else { return }
        router.selected = tab
        pendingTab = nil
    }
}
