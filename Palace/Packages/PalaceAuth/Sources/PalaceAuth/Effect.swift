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
/// an `@Sendable` `run` closure, an `isNone` marker set only by `.none`, and
/// `Action: Sendable` on `.send`. Change
/// both copies together, and do not add a third.
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
/// environment makes that crossing safe. `AuthEnvironment` holds only a
/// `@Sendable` closure and conforms to `Sendable` for exactly this reason.
///
/// ## Finish-line (gated follow-up, NOT this contract)
/// True unification collapses both copies into a shared SPM module that the app
/// target and every reducer package import. Until that module exists, this
/// mirror stays — kept identical, count-pinned, and documented here.
public struct Effect<Action, Environment: Sendable> {
    public let run: @Sendable (Environment) async -> Action?

    /// True only for `.none`. A closure cannot be compared, so this is how a
    /// runner skips scheduling a task that would do nothing.
    // PUBLIC_INTENT: the app's sign-in effect runner reads it across the package boundary.
    public let isNone: Bool

    public init(run: @escaping @Sendable (Environment) async -> Action?) {
        self.init(run: run, isNone: false)
    }

    private init(run: @escaping @Sendable (Environment) async -> Action?, isNone: Bool) {
        self.run = run
        self.isNone = isNone
    }

    public static var none: Effect<Action, Environment> {
        Effect(run: { _ in nil }, isNone: true)
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
