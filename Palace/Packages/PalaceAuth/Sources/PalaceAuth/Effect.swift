import Foundation

/// A side-effect produced by a reducer.
///
/// ## Why this type is duplicated (package-boundary mirror)
/// This is a deliberate, documented mirror of the canonical `Effect` defined
/// in the main target's `Palace/AppInfrastructure/Store.swift`. `PalaceAuth`
/// is a standalone SPM package that **must not import the app module**
/// (`Palace`) — doing so would invert the dependency graph (the app depends on
/// the package, never the reverse) and drag the entire app target into the
/// package's build. So the package keeps a local copy with the *same shape and
/// the same semantics* as the app copy, exactly as `Palace/Packages/PalaceCatalog`
/// keeps its own package-local mirrors of shared value types for the identical
/// boundary reason.
///
/// Because there are two copies, they can silently drift. This copy is kept
/// **semantically identical** to the canonical one: `Environment: Sendable`,
/// an `@Sendable` `run` closure, and `Action: Sendable` on `.send`. The
/// architecture probe in Contract F pins the total `struct Effect<Action, Environment`
/// count at exactly **2, both `Sendable`-constrained** — a third copy, or one of
/// these two losing the `Sendable` bound, fails that probe.
///
/// ## Semantics (mirrors `Store.Effect`)
/// Effects run on an unstructured `Task` and may feed a follow-up `Action`
/// back into the `Store`'s `send(_:)`. Use `.none` when a reducer has no
/// side-effect, `.send(action)` to dispatch an action, and `.task { env in ... }`
/// for async work that eventually yields an action (or `nil` to end the chain).
///
/// `Environment: Sendable` (Swift 6): the `@MainActor` `Store` hands the
/// environment to `run` from an `async` context that hops off the main actor,
/// so the environment value crosses an isolation boundary; a `Sendable`
/// environment makes that crossing safe. `AuthEnvironment` is an empty value
/// bag and conforms to `Sendable` for exactly this reason.
///
/// ## Finish-line (gated follow-up, NOT this contract)
/// True unification collapses both copies into a shared SPM module that the app
/// target and every reducer package import. Until that module exists, this
/// mirror stays — kept identical, count-pinned, and documented here.
public struct Effect<Action, Environment: Sendable> {
    public let run: @Sendable (Environment) async -> Action?

    public init(run: @escaping @Sendable (Environment) async -> Action?) {
        self.run = run
    }

    public static var none: Effect<Action, Environment> {
        Effect { _ in nil }
    }

    public static func send(_ action: Action) -> Effect<Action, Environment> where Action: Sendable {
        Effect { _ in action }
    }

    public static func task(
        _ work: @escaping @Sendable (Environment) async -> Action?
    ) -> Effect<Action, Environment> {
        Effect(run: work)
    }
}
