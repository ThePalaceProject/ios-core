//
// clean_with_provider.swift
// Fixture: PR #1044-style fix — the classifier is constructed with
// `currentAccountHostsProvider` referenced in scope. Detector MUST
// classify this as clean.
//

import Foundation

final class FixtureCleanWithProvider {
    func handle(response: HTTPURLResponse?, accountsManager: Any) {
        guard let response else { return }
        let classifier = AuthErrorClassifier(
            currentAccountHostsProvider: {
                (accountsManager as AnyObject).currentAccount?.authSurfaceHosts
            }
        )
        if response.statusCode == 401 {
            // The classifier short-circuits foreign-host 401s as .ok
            // before any mark-stale dispatch lands.
            (accountsManager as AnyObject).markCredentialsStale()
        }
    }
}
