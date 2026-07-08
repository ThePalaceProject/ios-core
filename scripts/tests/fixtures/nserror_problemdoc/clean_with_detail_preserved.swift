//
// clean_with_detail_preserved.swift
// Fixture: a function that receives a TPPProblemDocument and embeds
// `problemDocument.detail` in the NSError userInfo. Either title- or
// detail-preservation is sufficient — userFacingSignInError returns
// the (title, detail) tuple straight through.
//
// Detector MUST PASS.
//

import Foundation

final class FixtureDetailPreserved {
    // no-superpartner: D4-1 detector fixture, exercised by tests/test_check_nserror_problemdoc_preservation.py
    func wrap(problemDocument: TPPProblemDocument,
              completion: ((NSError) -> Void)?) {
        let userInfo: [String: Any] = [
            "NSLocalizedFailureReasonErrorKey": problemDocument.detail ?? ""
        ]
        let nsError = NSError(
            domain: "clientDomain",
            code: 403,
            userInfo: userInfo
        )
        completion?(nsError)
    }
}
