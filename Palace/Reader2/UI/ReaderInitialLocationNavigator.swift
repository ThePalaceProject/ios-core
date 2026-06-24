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
import PalaceLogging
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

    /// Set true if the post-first-paint restore `go(to:)` returned false — Readium
    /// could not resolve the saved/synced locator. Because the EPUB navigator's
    /// CONSTRUCTOR restore is disabled (`TPPEPUBViewController.navigatorConstructorInitialLocation`
    /// is always nil), the navigator is already at the publication's natural start,
    /// so a failed restore is a graceful degradation to page 1 — NOT a WebContent
    /// teardown / bounce. Observable for diagnostics + tests.
    private(set) var restoreDidDegradeToStart = false

    /// Test hook: fired (on the main actor) with the FINAL `go(to:)` Bool result
    /// once the restore (incl. retries) completes. Nil in production.
    var onRestoreAttempt: ((Bool) -> Void)?

    /// PP-4652: how many times to (re)try `go(to:)` before degrading to page 1,
    /// and the delay between tries. A DRM/Adobe EPUB decrypts + loads its
    /// WebContent more slowly than an open-access EPUB, so at `viewDidAppear`
    /// (when the gate fires) Readium's location-mapping table may not be
    /// populated yet — the first `go(to:)` then no-ops to `false` and #1084's
    /// single-shot gate gave up at the cover. Retrying until the table is ready
    /// restores the real position; the constructor restore stays disabled so a
    /// retried `go(to:)` cannot double-restore / tear down WebContent.
    private let maxRestoreAttempts: Int
    private let restoreRetryDelayNanos: UInt64

    init(
        initialLocation: Locator?,
        maxRestoreAttempts: Int = 12,
        restoreRetryDelayNanos: UInt64 = 250_000_000
    ) {
        self.initialLocation = initialLocation
        self.maxRestoreAttempts = max(1, maxRestoreAttempts)
        self.restoreRetryDelayNanos = restoreRetryDelayNanos
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Single restore authority: the navigator first-paints at its natural
            // start (constructor restore disabled), then this restores once the
            // WKWebView's location-mapping table is populated. For a DRM EPUB that
            // can lag past `viewDidAppear`, so `go(to:)` may no-op to false on the
            // first try (PP-4652: book reopened to the cover). Retry until it
            // resolves — each false attempt is a no-op (nothing navigated, nothing
            // torn down), so retrying restores the real position without
            // re-introducing the #1084 double-restore. Only a persistently
            // unresolvable locator (all attempts false) degrades to page 1, which
            // we record/log rather than silently discard.
            var restored = false
            for attempt in 0..<self.maxRestoreAttempts {
                restored = await navigator.go(to: location, options: NavigatorGoOptions(animated: false))
                if restored { break }
                if attempt < self.maxRestoreAttempts - 1, self.restoreRetryDelayNanos > 0 {
                    try? await Task.sleep(nanoseconds: self.restoreRetryDelayNanos)
                }
            }
            if !restored {
                self.restoreDidDegradeToStart = true
                Log.warn(#file, "Reader initial-location restore returned false after \(self.maxRestoreAttempts) attempt(s); remaining at start (page 1).")
            }
            self.onRestoreAttempt?(restored)
        }
    }
}
