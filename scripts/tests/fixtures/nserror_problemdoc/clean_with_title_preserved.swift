//
// clean_with_title_preserved.swift
// Fixture: a function that receives a TPPProblemDocument and embeds
// `problemDocument.title` directly into the NSError userInfo. The
// downstream userFacingSignInError(...) consumer can surface the
// server-supplied reason.
//
// Detector MUST PASS.
//

import Foundation

final class FixtureTitlePreserved {
    // no-superpartner: D4-1 detector fixture, exercised by tests/test_check_nserror_problemdoc_preservation.py
    func wrap(problemDocument: TPPProblemDocument,
              completion: ((NSError) -> Void)?) {
        let userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: problemDocument.title ?? "Sign-in failed"
        ]
        let nsError = NSError(
            domain: "clientDomain",
            code: 401,
            userInfo: userInfo
        )
        completion?(nsError)
    }
}
