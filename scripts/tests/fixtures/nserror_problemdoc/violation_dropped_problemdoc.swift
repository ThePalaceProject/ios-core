//
// violation_dropped_problemdoc.swift
// Fixture: a function that receives an upstream TPPProblemDocument via
// `(error as NSError).problemDocument` and then constructs a fresh
// NSError whose userInfo only carries `localizedDescription` — exactly
// the PP-3956 token-refresh re-wrap bug class.
//
// Detector MUST flag.
//

import Foundation

final class FixtureDroppedProblemDoc {
    // no-superpartner: D4-1 detector fixture, exercised by tests/test_check_nserror_problemdoc_preservation.py
    func executeTokenRefresh(error: Error,
                             completion: ((Error) -> Void)?) {
        // problemDoc binding from the upstream error.
        let problemDoc = (error as NSError).problemDocument
        _ = problemDoc

        // Generic re-wrap that drops the upstream problemDoc — fallback
        // "Invalid Credentials" leaks through to userFacingSignInError.
        let nsError = NSError(
            domain: "clientDomain",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Token refresh failed: \(error.localizedDescription)"]
        )
        completion?(nsError)
    }
}
