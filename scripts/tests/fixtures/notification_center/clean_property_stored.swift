//
// clean_property_stored.swift
// Fixture: PP-4329 canonical fix — the returned NSObjectProtocol token
// is captured in a stored property AND removed before re-registering.
// Detector MUST classify as clean.
//

import Foundation
import UIKit

final class FixturePropertyStored {
    private var firstRunFlowObserver: NSObjectProtocol?

    func startDeferredFirstRunFlow() {
        // Remove the previous observer (if any) before adding a new one.
        if let token = firstRunFlowObserver {
            NotificationCenter.default.removeObserver(token)
            firstRunFlowObserver = nil
        }
        firstRunFlowObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FixtureCatalogDidLoad"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startDeferredFirstRunFlow()
        }
    }
}
