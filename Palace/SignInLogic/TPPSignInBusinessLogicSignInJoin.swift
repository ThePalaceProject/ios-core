//
//  TPPSignInBusinessLogicSignInJoin.swift
//  The Palace Project
//

import Foundation

/// Sign-in work starts from four synchronous entry points: the OAuth redirect
/// handler, the OIDC callback handler, the bearer-token success arm, and the
/// basic-auth branch of `refreshAuthIfNeeded`. Each is reached from a
/// notification, a URL callback, or an `@objc` `Bool`-returning method, so none
/// of them can become `async`; the `Task` they start is a real sync-to-async
/// boundary rather than a hop that could be removed.
///
/// That leaves a test with nothing to await. Reading `isValidatingCredentials`
/// worked while `validateCredentials` took a completion handler, because the
/// flag stayed set for as long as the request was in flight. An awaited
/// validation clears it before control returns, so the same read samples a
/// window that has already closed (PP-5301).
///
/// Waiting on a wall-clock deadline instead is the `parallel-clone-starvation`
/// class (STARVE-001): it loses the CPU race under parallel simulator clones
/// and fails all three CI retries. So the handle is retained under XCTest and
/// joined on demand — the shape `AccountRegistryLoader` uses for its catalog
/// crawls.
///
/// Outside XCTest nothing is retained and the behaviour is exactly the detached
/// `Task` these call sites started before.
///
/// An entry keyed on `ObjectIdentifier` cannot be claimed by a later instance
/// at the same address: the retained task holds the instance, so the address
/// stays taken until the entry is joined and dropped.
@MainActor
private var inFlightSignInTasks: [ObjectIdentifier: [Task<Void, Never>]] = [:]

private let isRunningUnderXCTest =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

extension TPPSignInBusinessLogic {

    /// Start sign-in work from a synchronous caller. Joinable under XCTest.
    func startSignInTask(_ operation: @escaping @MainActor () async -> Void) {
        let task = Task { await operation() }
        guard isRunningUnderXCTest else { return }
        inFlightSignInTasks[ObjectIdentifier(self), default: []].append(task)
    }

    /// Test-only deterministic join. Awaits every sign-in task this instance
    /// started, including ones started while an earlier one was being awaited —
    /// the token-refresh arm starts validation from inside its own task.
    func _awaitSignInWorkForTesting() async {
        let key = ObjectIdentifier(self)
        while let pending = inFlightSignInTasks[key], !pending.isEmpty {
            inFlightSignInTasks[key] = []
            for task in pending { _ = await task.value }
        }
        inFlightSignInTasks[key] = nil
    }
}
