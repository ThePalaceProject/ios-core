import XCTest
@testable import PalaceAuth

/// Boundary + behavior tests for the package-local `Effect` mirror in
/// `PalaceAuth` (WS2 / Contract B).
///
/// Two things are pinned here:
/// 1. **Factory semantics** — `.none` / `.send` / `.task` must behave exactly
///    like the canonical `Store.Effect` in the app target. A drift (e.g. `.send`
///    dropping its action, `.task` ignoring the environment) fails a test.
/// 2. **The `Sendable` package boundary** — the reason this duplicate exists is
///    that `PalaceAuth` must not import the app module. The new
///    `Environment: Sendable` bound is what keeps the two copies semantically
///    identical; the compile-time witness below proves `AuthEnvironment`
///    satisfies it, so a dropped conformance breaks the build, not runtime.
final class EffectBoundaryTests: XCTestCase {

    /// A `Sendable` probe environment carrying an observable marker, so the
    /// env-threading through `run` can actually be asserted — `AuthEnvironment`
    /// is empty and cannot witness it.
    private struct ProbeEnv: Sendable {
        let marker: Int
    }

    // MARK: - Factory semantics (must mirror Store.Effect)

    func test_none_resolvesToNoFollowUpAction() async {
        let effect = Effect<Int, ProbeEnv>.none
        let result = await effect.run(ProbeEnv(marker: 7))
        XCTAssertNil(result, ".none must resolve to nil — a reducer with no side-effect ends the chain")
    }

    func test_send_deliversExactlyThatAction_regardlessOfEnvironment() async {
        let effect = Effect<Int, ProbeEnv>.send(42)
        let result = await effect.run(ProbeEnv(marker: -999))
        XCTAssertEqual(result, 42, ".send(x) must resolve to x and ignore the environment")
    }

    func test_task_runsClosureAndThreadsTheCallersEnvironment() async {
        // Reads the environment marker: proves `run` is invoked with the
        // caller's environment, not a default/discarded one. Kills a mutant
        // that swaps `.task` for `.none` or ignores the passed environment.
        let effect = Effect<Int, ProbeEnv>.task { env in env.marker * 2 }
        let result = await effect.run(ProbeEnv(marker: 21))
        XCTAssertEqual(result, 42, ".task must run the closure against the passed environment")
    }

    func test_task_returningNil_endsTheChain() async {
        let effect = Effect<Int, ProbeEnv>.task { _ in nil }
        let result = await effect.run(ProbeEnv(marker: 0))
        XCTAssertNil(result, ".task resolving to nil must end the effect chain")
    }

    func test_customInit_runsTheProvidedClosure() async {
        let effect = Effect<String, ProbeEnv>(run: { env in "marker=\(env.marker)" })
        let result = await effect.run(ProbeEnv(marker: 5))
        XCTAssertEqual(result, "marker=5", "init(run:) must store and invoke the exact closure supplied")
    }

    // MARK: - Package-boundary Sendable guarantee

    /// Compile-time witness for the boundary. The `Environment: Sendable` bound
    /// added to `Effect` requires `AuthEnvironment` — the environment the auth
    /// reducer declares its effects over — to be `Sendable`. If a future edit
    /// drops that conformance, THIS FILE FAILS TO COMPILE. That is the boundary
    /// guarantee: PalaceAuth's `Effect` stays semantically identical to the
    /// app's `Store.Effect` without importing the app module. The runtime half
    /// asserts the reducer's own effect type resolves.
    func test_authEnvironment_satisfiesSendableBound_andEffectResolvesOverIt() async {
        assertSendable(AuthEnvironment.self)
        let effect: Effect<AuthAction, AuthEnvironment> = .none
        let result = await effect.run(AuthEnvironment())
        XCTAssertNil(result, "AuthReducer's effect type must resolve — .none over AuthEnvironment yields no action")
    }

    /// The assertion is the generic constraint itself: a call that compiles
    /// proves `T: Sendable`. Intentionally no body.
    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}
