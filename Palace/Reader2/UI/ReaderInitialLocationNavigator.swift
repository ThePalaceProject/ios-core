//
//  ReaderInitialLocationNavigator.swift
//  Palace
//
//  Gates the initial `navigator.go(to:)` behind a WKWebView-ready signal.
//  Calling it before the WebView's first layout can resolve before Readium's
//  location table is populated and land the patron at chapter 1. The view
//  controller calls `signalReady()` from `viewDidAppear`; `go(to:)` fires once,
//  after both the navigator is attached and the ready signal has fired.
//  Depends only on `NavigatorGoTo` so tests can use a recording stub.
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
    /// could not resolve the saved/synced locator. The constructor restore is
    /// disabled, so the navigator is already at the start and this is a graceful
    /// degradation to page 1.
    private(set) var restoreDidDegradeToStart = false

    /// Test hook: fired (on the main actor) with the FINAL `go(to:)` Bool result
    /// once the restore (incl. retries) completes. Nil in production.
    var onRestoreAttempt: ((Bool) -> Void)?

    /// PP-4652: how many times to (re)try `go(to:)` before degrading to page 1,
    /// and the delay between tries. A DRM EPUB loads its WebContent more slowly,
    /// so at `viewDidAppear` the location table may not be ready and the first
    /// `go(to:)` returns `false`.
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
            // Single restore authority (constructor restore is disabled). Each
            // `false` attempt navigates nothing, so retrying is safe (PP-4652,
            // #1084). Only a locator that never resolves degrades to page 1,
            // which is recorded and logged.
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
