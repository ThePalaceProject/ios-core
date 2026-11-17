//
//  PP-5070 — notices a managed configuration that arrives or changes after
//  launch. Apple does not guarantee the configuration is present before first
//  launch, and an MDM can change it while the app runs, so the first-run read
//  alone is not enough.
//
//  `UserDefaults.didChangeNotification` fires for every defaults write, so the
//  watcher compares the configuration's fingerprint with the last one seen and
//  does nothing when it has not changed (always, on an unmanaged install).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

final class ManagedLibraryConfigurationWatcher {

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let preconfigurator: ManagedLibraryPreconfigurator

    /// Identity of the payload last seen, so an unrelated defaults write costs
    /// one dictionary read and a string compare.
    ///
    /// Seeded at init from the SAME function `reevaluate` uses. Seeding it from
    /// a different notion of identity would make the first evaluation of every
    /// watcher a spurious change.
    private var lastSeenIdentity: String?

    private var token: NSObjectProtocol?

    init(
        defaults: UserDefaults,
        preconfigurator: ManagedLibraryPreconfigurator,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.preconfigurator = preconfigurator
        self.notificationCenter = notificationCenter
        self.lastSeenIdentity = ManagedAppConfiguration.configurationIdentity(defaults: defaults)
    }

    deinit {
        if let token { notificationCenter.removeObserver(token) }
    }

    /// Begins watching. `onDecision` fires for every configuration change the
    /// watcher acts on, so the caller can both dismiss a picker it has already
    /// put on screen AND keep trying when the configuration is real but not yet
    /// actionable. Map the decision with
    /// `ManagedLibraryPreconfigurator.watchAction(for:)`.
    ///
    /// Idempotent: calling twice does not stack observers.
    func start(onDecision: @escaping (ManagedLibraryDecision) -> Void) {
        guard token == nil else { return }
        token = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.reevaluate(onDecision: onDecision)
        }
    }

    func stop() {
        if let token { notificationCenter.removeObserver(token) }
        token = nil
    }

    /// The filter, then the apply. Exposed for tests so the decision can be
    /// driven without posting notifications.
    func reevaluate(onDecision: (ManagedLibraryDecision) -> Void) {
        // The identity of the PAYLOAD, not of the parsed configuration.
        //
        // Parsed was wrong in a way that hid the most likely fault: a payload
        // too malformed to parse has no parsed fingerprint, so every malformed
        // payload looked alike. An administrator fixing a typo to a different
        // typo changed nothing we could see, and their second attempt was
        // dropped without ever reaching diagnostics. The same blindness swallowed
        // a change to an unusable extra library while the selected one held
        // still.
        let identity = ManagedAppConfiguration.configurationIdentity(defaults: defaults)
        guard identity != lastSeenIdentity else { return }
        lastSeenIdentity = identity

        guard identity != nil else {
            // The configuration was removed while the app is still managed —
            // an administrator clearing the value, not management ending. We
            // deliberately do NOT undo the selection: the library is the
            // student's now, and silently deselecting one they may be mid-book
            // in is a worse surprise than leaving it.
            //
            // The other case, management ending altogether, never reaches here:
            // Apple removes the managed app and its whole data container, so
            // there is nothing left to undo and no code of ours to run.
            Log.info(#file, "Managed configuration was removed; leaving the current library alone.")
            return
        }

        let decision = preconfigurator.applyIfNeeded()
        Log.info(#file, "Managed configuration changed after launch: \(decision)")
        // Reported whatever it is. A configuration that arrives before the
        // registry has loaded is NOT a dead end — the caller needs to know so it
        // can keep listening, which is the case this callback used to drop.
        onDecision(decision)
    }
}
