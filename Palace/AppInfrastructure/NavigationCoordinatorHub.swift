import Foundation

/// Resolves "which navigation stack is on screen" for the non-view code that has
/// to push a route — the reader services, `BookService`, the audiobook session
/// manager, the account-switch cleanup.
///
/// PP-5022 — why this is a registry and not a single pointer. The hub used to
/// hold one global `weak var coordinator` that every tab's `NavigationHostView`
/// overwrote from its root's `.onAppear`. Four sibling `NavigationStack`s write
/// that slot, so the winner is an ordering accident: an offscreen tab's root
/// re-appearing (which the tab-switch pop-to-root provokes) leaves the pointer
/// aimed at a stack the patron cannot see. Every reader open then pushed onto
/// that stack — `EPUBReaderView.onAppear` fired, nothing appeared on screen, and
/// the My Books Read button looked dead until the app was relaunched.
///
/// Registration is keyed by `AppTab` and resolution asks the tab router which tab
/// is actually selected, so a late registration can no longer hijack the answer.
/// When the selected tab has no stack the hub returns `nil` rather than some other
/// tab's stack: callers have visible fallbacks (a modal present, an "unable to
/// open" alert), and a wrong-but-plausible answer is what made the failure silent.
///
/// Invariant worth stating: `NavigationHostView` REGISTERS through the injected
/// `\.appContainer`, while every consumer (`ReaderService`, `BookService`,
/// `BookCellModel`, `BookDetailViewModel`, `AudiobookSessionManager`) RESOLVES
/// through `AppContainer.production()`. Those agree only because the app injects
/// `production()` at both scene entry points and `AppContainerKey.defaultValue`
/// is `production()`. Placing a different container in `\.appContainer` in the
/// app (as opposed to a test) would split writers from readers and reproduce
/// this defect by another route.
final class NavigationCoordinatorHub {
    /// Required, no default: a hub built without a router silently degrades to
    /// `lastRegistered` — which IS the PP-5022 behavior. Making the caller state
    /// it (even as `nil`) keeps the un-wired state unrepresentable by accident
    /// rather than merely untested.
    init(tabRouterHub: AppTabRouterHub?) {
        self.tabRouterHub = tabRouterHub
    }

    /// Weak box — the hub must never keep a torn-down stack alive, or it would
    /// resurrect the stale-target defect it exists to prevent.
    private struct WeakCoordinator {
        weak var value: NavigationCoordinator?
    }

    private var byTab: [AppTab: WeakCoordinator] = [:]

    /// Last registration of any kind. Used only when no tab can be resolved —
    /// previews, unit tests, and hosts that are not one of the tab stacks.
    private weak var lastRegistered: NavigationCoordinator?

    /// Weak because the hubs are peers in the container graph, not owners of
    /// each other. `private` (and only ever written by `init`) so a hub cannot
    /// be re-pointed at another container's router after construction — a
    /// post-hoc assignment is how one container silently re-aims another's hub.
    /// `weak var` rather than `let` only because Swift has no `weak let`.
    private weak var tabRouterHub: AppTabRouterHub?

    /// Registers a stack under the tab that hosts it. `tab` is `nil` for a host
    /// with no tab identity — such a host provides only the fallback and never
    /// claims a tab slot.
    @MainActor
    func register(_ coordinator: NavigationCoordinator, for tab: AppTab?) {
        if let tab {
            byTab[tab] = WeakCoordinator(value: coordinator)
        }
        lastRegistered = coordinator
    }

    /// The stack of a specific tab, selected or not. The tab-switch pop-to-root
    /// uses this to reset the tab being LEFT.
    @MainActor
    func coordinator(for tab: AppTab) -> NavigationCoordinator? {
        byTab[tab]?.value
    }

    /// Every stack still alive, in no particular order.
    ///
    /// PP-5051 — teardown that has to reach tabs the patron is NOT looking at.
    /// While a tab switch reset the tab being left, the only stack that could
    /// hold stale content was the visible one, so `coordinator` was enough. Tabs
    /// now keep their stacks, so anything clearing content for the whole app —
    /// an account switch, say — has to say so explicitly.
    @MainActor
    func allRegisteredCoordinators() -> [NavigationCoordinator] {
        var all = byTab.values.compactMap(\.value)
        // Include a tabless host too. All four production hosts pass a real tab,
        // so this is unreachable today — but `NavigationHostView.tab` is
        // deliberately optional, and a stack that a whole-app sweep cannot reach
        // is exactly the offscreen-stale-content defect the sweep exists for.
        if let fallback = lastRegistered, !all.contains(where: { $0 === fallback }) {
            all.append(fallback)
        }
        return all
    }

    /// The stack the patron is looking at.
    @MainActor
    var coordinator: NavigationCoordinator? {
        guard let tab = tabRouterHub?.currentTab else { return lastRegistered }
        return byTab[tab]?.value
    }
}
