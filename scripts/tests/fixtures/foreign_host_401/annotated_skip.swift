//
// annotated_skip.swift
// Fixture: a 401 dispatch site that is structurally scoped by closure
// capture (not by an authSurfaceHosts check) and uses the
// `// no-host-scoping:` escape-hatch annotation. Detector MUST treat
// this as clean.
//

import Foundation

final class FixtureAnnotatedSkip {
    func onRefreshFailed(error: Error, accountsManager: Any) {
        // capturedAccountId is bound at refresh-start time, so the
        // dispatch is already scoped to the originating account.
        let capturedAccountId: String? = nil
        if let nsError = error as? NSError, nsError.code == 401 {
            // no-host-scoping: token-refresh closure binds capturedAccountId by design
            (accountsManager as AnyObject)
                .userAccount(for: capturedAccountId ?? "")
                .markCredentialsStale()
        }
    }
}
