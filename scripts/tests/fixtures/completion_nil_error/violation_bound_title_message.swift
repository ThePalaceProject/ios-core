//
// violation_bound_title_message.swift
// Fixture: same bug class as violation_string_literals.swift, but title and
// message are bound via `let` to string literals earlier in the same function
// body and passed by NAME — not literal — at the call. The detector predicate
// covers both shapes because the consumer-side suppression behavior is
// identical regardless of whether the args are inline literals or
// recently-bound variables.
//

import Foundation

final class FixtureBoundTitleMessage {
    var completion: ((Error?, String?, String?) -> Void)?

    func onSAMLPatronIdFailed() {
        let title = "Sign In Failed"
        let message = "Unable to parse authentication info"
        // No NSError synthesized — the consumer's `if let error` guard fails
        // and the alert never shows. Same wall-failure shape.
        completion?(nil, title, message)
    }
}
