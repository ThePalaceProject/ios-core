//
// annotated_skip.swift
// Fixture: a function that drops the upstream problemDoc BUT carries the
// `// no-problemdoc-preservation: <reason>` escape hatch on the line
// above the NSError construction. The contract reviewer accepted the
// rationale (e.g. the upstream problemDoc is logged separately and the
// caller intentionally returns a generic wrapper).
//
// Detector MUST PASS.
//

import Foundation

final class FixtureAnnotatedSkip {
    // no-superpartner: D4-1 detector fixture, exercised by tests/test_check_nserror_problemdoc_preservation.py
    func executeTokenRefresh(error: Error,
                             completion: ((Error) -> Void)?) {
        let problemDoc = (error as NSError).problemDocument
        _ = problemDoc

        // no-problemdoc-preservation: caller logs upstream problemDoc via
        // TPPErrorLogger.logNetworkError(...) before this re-wrap; the
        // sign-in modal here is structurally generic by product decision.
        let nsError = NSError(
            domain: "clientDomain",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Token refresh failed: \(error.localizedDescription)"]
        )
        completion?(nsError)
    }
}
