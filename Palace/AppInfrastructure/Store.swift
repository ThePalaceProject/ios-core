import Combine
import Foundation

/// A side-effect produced by a reducer.
///
/// Effects run on an unstructured `Task` and may feed a follow-up `Action`
/// back into the Store's `send(_:)`. Use `.none` when a reducer has no
/// side-effect, `.send(action)` to dispatch synchronously on the main actor,
/// and `.task { env in ... }` for async work that eventually yields an
/// action (or `nil` to end the chain).
struct Effect<Action, Environment> {
    let run: (Environment) async -> Action?

    static var none: Effect<Action, Environment> {
        Effect { _ in nil }
    }

    static func send(_ action: Action) -> Effect<Action, Environment> {
        Effect { _ in action }
    }

    static func task(
        _ work: @escaping (Environment) async -> Action?
    ) -> Effect<Action, Environment> {
        Effect(run: work)
    }
}

/// A lightweight unidirectional Store for SwiftUI ViewModels.
///
/// Actions flow in via `send(_:)`; the reducer is a pure closure that
/// mutates state synchronously and returns a single `Effect`; the store
/// runs the effect in a detached Task and recursively feeds any follow-up
/// action back through the reducer. `Environment` holds injected
/// collaborators so effects can be unit-tested with substituted dependencies.
///
/// Not TCA: no scoped reducers, no pullback, no TestStore. One reducer
/// closure per domain, effects as `async` closures capturing the environment.
@MainActor
final class Store<State, Action, Environment>: ObservableObject {
    @Published private(set) var state: State
    private let environment: Environment
    private let reduce: (inout State, Action) -> Effect<Action, Environment>

    init(
        initialState: State,
        environment: Environment,
        reduce: @escaping (inout State, Action) -> Effect<Action, Environment>
    ) {
        self.state = initialState
        self.environment = environment
        self.reduce = reduce
    }

    func send(_ action: Action) {
        let effect = reduce(&state, action)
        Task { [environment, weak self] in
            guard let nextAction = await effect.run(environment) else { return }
            self?.send(nextAction)
        }
    }

    /// Awaitable variant: mutates state synchronously through the reducer,
    /// then runs the effect chain to completion before returning. Use this
    /// from ViewModel methods whose callers must observe the post-effect
    /// state (e.g. an `async` search filter where the test asserts on
    /// visibleBooks after `await filterBooks(...)`).
    func sendAwait(_ action: Action) async {
        var current: Action? = action
        while let action = current {
            let effect = reduce(&state, action)
            current = await effect.run(environment)
        }
    }
}
