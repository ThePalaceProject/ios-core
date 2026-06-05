//
// violation_unstored_observer.swift
// Fixture: the PP-4329 bug class verbatim — closure-form addObserver
// whose returned NSObjectProtocol token is discarded, and the
// enclosing class has no removeObserver cleanup anywhere. Detector
// MUST flag D5-1.
//

import Foundation
import UIKit

final class FixtureUnstoredObserver {
    func startDeferredFirstRunFlow() {
        // No `let token = ...` — the return value is silently discarded.
        // If startDeferredFirstRunFlow() is re-entered (e.g. from a
        // notification fired inside the block), a fresh observer
        // accumulates on every recursion — the PP-4329 leak.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FixtureCatalogDidLoad"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startDeferredFirstRunFlow()
        }
    }
}
