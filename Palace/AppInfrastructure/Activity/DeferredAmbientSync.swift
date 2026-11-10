//
//  DeferredAmbientSync.swift
//  Palace
//
//  Holds a sync nobody asked for (PP-5508) until someone can see the result.
//

import Combine
import Foundation

/// Runs `perform` at once while the app is visible. Otherwise marks it
/// pending and runs it once on the next transition to visible; requests made
/// while pending fold into that one run. With no policy it always runs at once.
@MainActor
final class DeferredAmbientSync {
    private let policy: ActivityPolicy?
    private let perform: @MainActor () -> Void
    private(set) var isPending = false
    private var visibility: AnyCancellable?

    init(policy: ActivityPolicy?, perform: @escaping @MainActor () -> Void) {
        self.policy = policy
        self.perform = perform
        visibility = policy?.statePublisher
            .map(ActivityRules.isVisible)
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.runPending() }
    }

    func request() {
        guard let policy, policy.ambientSync() == .deferUntilVisible else {
            perform()
            return
        }
        isPending = true
    }

    private func runPending() {
        guard isPending else { return }
        isPending = false
        policy?.recordDeferredAmbientSyncRun()
        perform()
    }
}
