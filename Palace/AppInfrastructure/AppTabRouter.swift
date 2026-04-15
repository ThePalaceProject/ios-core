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
    static let shared = AppTabRouterHub()
    private init() {}
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

    @MainActor
    func applyPending() {
        guard let tab = pendingTab, let router else { return }
        router.selected = tab
        pendingTab = nil
    }
}
