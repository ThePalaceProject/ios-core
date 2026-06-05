//
// clean_annotated.swift
// Fixture: an AppDelegate-lifetime observer whose author explicitly
// opted out via `// no-observer-storage: <reason>` because the
// observer is meant to live for the entire app lifetime and never
// deregister. Detector MUST classify as clean (annotation escape).
//

import Foundation
import UIKit

final class FixtureAnnotated {
    func registerLifetimeObserver() {
        // no-observer-storage: app-lifetime observer; AppDelegate is
        // alive until termination, removeObserver is a no-op.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            // fire-and-forget telemetry — intentionally never torn down.
        }
    }
}
