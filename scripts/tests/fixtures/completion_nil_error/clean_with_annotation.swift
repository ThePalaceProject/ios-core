//
// clean_with_annotation.swift
// Fixture: completion(nil, title, message) explicitly annotated as
// intentional via `// no-nil-error-suppression: <reason>`. The annotation
// suppresses the detector — same escape-hatch pattern as the sibling
// detectors (// no-host-scoping:, // no-superpartner:, etc.).
//

import Foundation

final class FixtureAnnotated {
    var completion: ((Error?, String?, String?) -> Void)?

    func onTransientStateThatConsumerHandlesElsewhere() {
        let title = "Retrying"
        let message = "Reconnecting…"
        // no-nil-error-suppression: progress-update path; consumer renders
        // title/message via a separate progress branch that doesn't gate on
        // `if let error`.
        completion?(nil, title, message)
    }
}
