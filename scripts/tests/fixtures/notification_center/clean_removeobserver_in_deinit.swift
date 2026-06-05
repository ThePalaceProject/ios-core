//
// clean_removeobserver_in_deinit.swift
// Fixture: token NOT captured per-observer, but the enclosing class
// has a `deinit { NotificationCenter.default.removeObserver(self) }`
// that catches selector-form and closure-form observers via the
// object identity. Detector MUST classify as clean — cleanup evidence
// is present at the type level.
//

import Foundation

final class FixtureDeinitCleanup {
    func wireObservers() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FixtureSomething"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSomething()
        }
    }

    private func handleSomething() {}

    deinit {
        // Type-level cleanup — all observers added against this instance
        // get torn down here. PP-4329-safe at the class lifecycle level.
        NotificationCenter.default.removeObserver(self)
    }
}
