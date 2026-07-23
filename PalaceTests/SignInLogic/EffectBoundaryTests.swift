import XCTest
import PalaceAuth

/// App-bundle boundary + behavior tests for the package-local `Effect` mirror
/// in `PalaceAuth` (WS2 / Contract B).
///
/// This class exercises `PalaceAuth`'s `Effect` *as the app target compiles it*
/// — proving the app-side consumer (`TPPSignInBusinessLogic`, which calls
/// `AuthReducer.reduce`) still type-checks against the now-`Sendable`-bounded
/// `Effect`. The identical package-target class (`PalaceAuthTests`) proves the
/// same through a standalone `swift test`; both are needed because a drift can
/// hide in either compilation path.
///
/// Deliberately imports only `PalaceAuth` (no `@testable import Palace`) so the
/// app's internal `Store.Effect` is not in scope and `Effect` here is
/// unambiguously the package copy under test.
final class EffectBoundaryTests: XCTestCase {

    /// A `Sendable` probe environment carrying an observable marker, so
    /// env-threading through `run` can actually be asserted — `AuthEnvironment`
    /// is empty and cannot witness it.
    private struct ProbeEnv: Sendable {
        let marker: Int
    }

    // MARK: - Factory semantics (must mirror the app's Store.Effect)

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
        // caller's environment. Kills a mutant that swaps `.task` for `.none`
        // or discards the passed environment.
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
    /// on `Effect` requires `AuthEnvironment` — the environment the auth
    /// reducer declares its effects over — to be `Sendable`. If a future edit
    /// drops that conformance, THIS FILE FAILS TO COMPILE. That compile failure
    /// IS the boundary guarantee: PalaceAuth's `Effect` stays semantically
    /// identical to the app's `Store.Effect` without importing the app module.
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
