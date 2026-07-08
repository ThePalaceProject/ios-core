//
// violation_nserror_code.swift
// Fixture: Phase-1a-revised survivor — uses `nsError.code == 401`
// rather than the `statusCode == 401` form. Detector MUST flag.
//

import Foundation

final class FixtureNSErrorCode {
    func onRefreshFailed(error: Error, accountsManager: Any) {
        if let nsError = error as? NSError, nsError.code == 401 {
            // Same bug class via the NSError bridge form. The architect
            // review caught this shape on TPPNetworkExecutor.swift:582 —
            // statusCode-only predicates miss it.
            (accountsManager as AnyObject).markCredentialsStale()
        }
    }
}
