//
//  ReaderInitialLocationNavigator.swift
//  Palace
//
//  P0 #3 (swarm `swarm_f3b9b087`): gates the initial `navigator.go(to:)`
//  call behind a WKWebView-ready signal.
//
//  Why this exists:
//
//  `TPPBaseReaderViewController.viewDidLoad` used to launch the initial
//  navigation as an unguarded `Task { await navigator.go(to: initialLocation) }`.
//  Readium's EPUB navigator wraps a WKWebView whose first-paint completes
//  asynchronously *after* `viewDidLoad` returns. Calling `go(to:)` before
//  the WebView has finished its initial layout occasionally lands the
//  user at chapter 1 instead of the saved position — `go(to:)` resolves
//  before the navigator's internal location-mapping table has been
//  populated, and falls back to the publication's start.
//
//  This helper holds the `initialLocation` and a ready latch. The
//  view controller calls `signalReady()` from `viewDidAppear` — by then
//  the WKWebView has reported its first paint and the navigator's
//  location table is populated. The `go(to:)` call fires exactly once,
//  after both the navigator is attached AND the ready signal has fired.
//
//  Testability: the helper depends only on the slim `NavigatorGoTo`
//  protocol below, so it can be exercised with a recording stub in
//  `PalaceTests/Reader2/TPPBaseReaderViewControllerInitialLocationTests.swift`.
//  Production `Navigator` instances satisfy the protocol via the
//  conformance declaration in `TPPBaseReaderViewController`.
//

import Foundation
import ReadiumNavigator
import ReadiumShared

/// Minimal slice of `Navigator` required by `ReaderInitialLocationNavigator`.
/// Production `Navigator` conformers (PDF / EPUB navigators) declare
/// conformance at the call site in `TPPBaseReaderViewController`.
@MainActor
protocol NavigatorGoTo: AnyObject {
    @discardableResult
    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool
}

@MainActor
final class ReaderInitialLocationNavigator {

    /// Set once at construction. Nil means "no restore — open at the
    /// publication's natural start".
    private let initialLocation: Locator?

    /// Weak ref to the navigator. The owning VC keeps the strong ref.
    private weak var navigator: NavigatorGoTo?

    /// Tripped from `viewDidAppear` (production) or directly (tests).
    private var isReady: Bool = false

    /// Latch so we never fire `go(to:)` more than once. `viewDidAppear`
    /// can fire multiple times across a VC's lifecycle; we must navigate
    /// to the saved location exactly once on the initial entry.
    private var didNavigate: Bool = false

    init(initialLocation: Locator?) {
        self.initialLocation = initialLocation
    }

    /// Called from the VC's init / viewDidLoad once the navigator is
    /// installed. If the ready signal has already fired (rare lifecycle
    /// race) we navigate immediately; otherwise we wait.
    func attach(navigator: NavigatorGoTo) {
        self.navigator = navigator
        navigateIfReady()
    }

    /// Tripped from `viewDidAppear`. Safe to call multiple times —
    /// subsequent calls are no-ops because of the `didNavigate` latch.
    func signalReady() {
        isReady = true
        navigateIfReady()
    }

    private func navigateIfReady() {
        guard !didNavigate else { return }
        guard isReady else { return }
        guard let navigator = navigator else { return }
        guard let location = initialLocation else {
            // No initial location to restore. Latch anyway so we don't
            // keep re-checking on every `signalReady`.
            didNavigate = true
            return
        }

        didNavigate = true
        Task { @MainActor in
            await navigator.go(to: location, options: NavigatorGoOptions(animated: false))
        }
    }
}
