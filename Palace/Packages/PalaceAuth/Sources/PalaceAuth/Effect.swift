import Foundation

/// A side-effect produced by a reducer.
///
/// Mirrors the `Effect` type defined in the main target's
/// `Palace/AppInfrastructure/Store.swift` so PalaceAuth's reducers can
/// declare effects without importing the app module. Same shape, same
/// semantics — when impl 4 wires the package, the main-target copy
/// becomes redundant for auth callers (other reducers in the app keep
/// using the local one until their packages catch up).
public struct Effect<Action, Environment> {
    public let run: (Environment) async -> Action?

    public init(run: @escaping (Environment) async -> Action?) {
        self.run = run
    }

    public static var none: Effect<Action, Environment> {
        Effect { _ in nil }
    }

    public static func send(_ action: Action) -> Effect<Action, Environment> {
        Effect { _ in action }
    }

    public static func task(
        _ work: @escaping (Environment) async -> Action?
    ) -> Effect<Action, Environment> {
        Effect(run: work)
    }
}
