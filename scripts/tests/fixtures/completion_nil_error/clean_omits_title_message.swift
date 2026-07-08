//
// clean_omits_title_message.swift
// Fixture: completion has no title/message after the nil error — different
// arity or non-string args. The consumer-suppression bug class doesn't apply.
// Detector MUST NOT flag any of these shapes.
//

import Foundation

final class FixtureNoTitleMessage {
    var oneArgCompletion: ((Error?) -> Void)?
    var twoArgCompletion: ((Error?, Bool) -> Void)?
    var passthroughCompletion: ((Error?, URLResponse?, Error?) -> Void)?

    func emitOneArg() {
        // Single-arg shape — there is no title/message position to suppress.
        oneArgCompletion?(nil)
    }

    func emitTwoArgBool() {
        // Second arg is a bool, not a string — no consumer-side alert path
        // gated on `if let title`.
        twoArgCompletion?(nil, false)
    }

    func emitFailurePassthrough(response: URLResponse?, error: Error?) {
        // Args 2-3 are variable references to non-string types (URLResponse,
        // Error). This is the TPPNetworkExecutor.swift:464 / :484 shape —
        // failure-passthrough where the error IS supplied via the third arg.
        passthroughCompletion?(nil, response, error)
    }
}
