//
//  ManagedLibraryConfigurationWatcher.swift
//  Palace
//
//  PP-5070 — notices a managed configuration that arrives, or changes, AFTER
//  the app has already decided what to do on launch.
//
//  ## Why this exists
//
//  The first-run path reads `com.apple.configuration.managed` once and never
//  looks again. That is only correct if the configuration is guaranteed to be
//  present before the app's first launch, and nothing in Apple's documentation
//  promises that. If it lands even a second late, the app shows the library
//  picker — on precisely the launch the feature exists to improve — and then
//  never reconsiders, because the first-run flow marks itself done.
//
//  That is the same defect the registry wait already fixes, one layer up: there
//  the LIBRARY LIST arrived late, here the CONFIGURATION does. Watching the key
//  removes the app's dependence on Apple's delivery timing entirely, which is
//  worth more than any answer a test MDM could give us about what that timing
//  happens to be today.
//
//  An MDM may also change a device's configuration while the app is installed
//  and running — moving a device between division groups mid-year is the
//  obvious case — so watching is the correct implementation regardless.
//
//  ## Why it filters before acting
//
//  `UserDefaults.didChangeNotification` fires for EVERY defaults write the app
//  makes, which on this app is constant. Re-running the apply path on each one
//  would walk the account registry for a URL-keyed configuration. So the
//  watcher compares the configuration's fingerprint against the last one it
//  saw and does nothing at all when it has not moved — the overwhelmingly
//  common case, including every unmanaged install, where it stays nil forever.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

final class ManagedLibraryConfigurationWatcher {

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let preconfigurator: ManagedLibraryPreconfigurator

    /// Fingerprint of the configuration last seen, so an unrelated defaults
    /// write costs one dictionary read and a string compare.
    private var lastSeenFingerprint: String?

    private var token: NSObjectProtocol?

    init(
        defaults: UserDefaults,
        preconfigurator: ManagedLibraryPreconfigurator,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.preconfigurator = preconfigurator
        self.notificationCenter = notificationCenter
        self.lastSeenFingerprint = preconfigurator.currentConfiguration?.fingerprint
    }

    deinit {
        if let token { notificationCenter.removeObserver(token) }
    }

    /// Begins watching. `onApplied` fires only when a configuration actually
    /// took effect, so a caller can dismiss a library picker it has already put
    /// on screen.
    ///
    /// Idempotent: calling twice does not stack observers.
    func start(onApplied: @escaping (ManagedLibraryDecision) -> Void) {
        guard token == nil else { return }
        token = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.reevaluate(onApplied: onApplied)
        }
    }

    func stop() {
        if let token { notificationCenter.removeObserver(token) }
        token = nil
    }

    /// The filter, then the apply. Exposed for tests so the decision can be
    /// driven without posting notifications.
    func reevaluate(onApplied: (ManagedLibraryDecision) -> Void) {
        let fingerprint = preconfigurator.currentConfiguration?.fingerprint
        guard fingerprint != lastSeenFingerprint else { return }
        lastSeenFingerprint = fingerprint

        guard fingerprint != nil else {
            // The MDM removed the configuration. Deliberately NOT undone: the
            // library is the student's now, and silently removing a library
            // someone may be mid-book in would be a worse surprise than leaving
            // it. Apple removes the app and its data outright when management
            // ends, so the "clean up after us" case is already handled by the
            // system rather than by us.
            Log.info(#file, "Managed configuration was removed; leaving the current library alone.")
            return
        }

        let decision = preconfigurator.applyIfNeeded()
        Log.info(#file, "Managed configuration changed after launch: \(decision)")
        if case .apply = decision {
            onApplied(decision)
        }
    }
}
