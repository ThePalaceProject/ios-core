//
// violation_missing_guard.swift
// Fixture: a function with a raw statusCode == 401 dispatch and no
// host-scoping reference. Detector MUST flag.
//

import Foundation

final class FixtureMissingGuard {
    func handle(response: HTTPURLResponse?, accountsManager: Any) {
        guard let response else { return }
        if response.statusCode == 401 {
            // Direct mark-stale dispatch with no host scoping — exactly
            // the PR #1018 / PR #1044 bug class.
            (accountsManager as AnyObject).markCredentialsStale()
            Task {
                _ = await someCoordinator.refreshCredentialsIfNeeded(reason: .unknown401)
            }
        }
    }
}
