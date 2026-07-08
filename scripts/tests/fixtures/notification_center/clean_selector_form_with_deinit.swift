//
// clean_selector_form_with_deinit.swift
// Fixture: SELECTOR-form addObserver (NOT the closure form, NOT the
// PP-4329 bug class) paired with a `removeObserver(self)` in deinit.
// Detector MUST classify as clean — the selector form is out of
// scope per the architect contract, and even if a sibling closure-
// form appeared here, the deinit cleanup would cover it.
//

import Foundation

final class FixtureSelectorWithDeinit {
    func wireObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTrigger(_:)),
            name: NSNotification.Name("FixtureTrigger"),
            object: nil
        )
    }

    @objc private func handleTrigger(_ note: Notification) {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
