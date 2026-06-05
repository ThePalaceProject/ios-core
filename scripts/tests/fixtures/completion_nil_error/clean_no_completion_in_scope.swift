//
// clean_no_completion_in_scope.swift
// Fixture: false-positive immunity check. The file has nil-first-arg calls,
// string literals, and let-bindings — but the call sites are NOT completion-
// shaped (different receiver names like `delegate`, `onResult`). Detector
// MUST NOT flag.
//

import Foundation

final class FixtureNoCompletionShape {
    var delegate: ((Error?, String?, String?) -> Void)?
    var onResult: ((Error?, String?) -> Void)?

    func deliverDelegateCallback() {
        let title = "Delegate Result"
        let message = "All good"
        // Receiver does NOT end in `completion`. Detector predicate requires
        // a `*completion` identifier.
        delegate?(nil, title, message)
    }

    func deliverOnResult() {
        onResult?(nil, "Result body")
    }
}
