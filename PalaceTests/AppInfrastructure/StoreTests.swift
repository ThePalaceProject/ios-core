import XCTest
import Combine
@testable import Palace

/// Contract tests for the lightweight `Store` pattern that underpins
/// unidirectional-flow ViewModels in Palace 3.0.0.
///
/// The Store's three load-bearing promises:
///   1. Reducers are pure closures: `(inout State, Action) -> Effect`.
///      They can be unit-tested without a Store.
///   2. Effects run via Task and may feed a follow-up Action back through
///      the same reducer. State updates remain on the main actor.
///   3. `@Published state` emits in order, giving SwiftUI a single source
///      of truth with no race between reads and writes.
@MainActor
final class StoreTests: XCTestCase {

    // MARK: - Fixtures

    private struct TestState: Equatable {
        var counter: Int = 0
    }

    private enum TestAction: Equatable {
        case increment
        case triggerEffect
        case setTo(Int)
    }

    private struct TestEnvironment {
        let yield: Int
    }

    /// A reducer exercising the three effect shapes: `.none`, `.task`, `.send`.
    private static func makeReducer() -> (inout TestState, TestAction) -> Effect<TestAction, TestEnvironment> {
        { state, action in
            switch action {
            case .increment:
                state.counter += 1
                return .none
            case .triggerEffect:
                return .task { env in .setTo(env.yield) }
            case .setTo(let value):
                state.counter = value
                return .none
            }
        }
    }

    // MARK: - Reducer purity

    @MainActor
    func testReducer_canBeExercisedWithoutAStore() {
        var state = TestState(counter: 5)
        let reduce = Self.makeReducer()
        _ = reduce(&state, .increment)
        XCTAssertEqual(state.counter, 6,
                       "Reducer must mutate the inout state directly — that's why we can unit-test it without a Store")
    }

    // MARK: - Synchronous state mutation

    @MainActor
    func testSend_synchronousReducer_updatesStateBeforeReturning() {
        let store = Store(
            initialState: TestState(),
            environment: TestEnvironment(yield: 0),
            reduce: Self.makeReducer()
        )
        store.send(.increment)
        XCTAssertEqual(store.state.counter, 1,
                       "State must be observable immediately after send for a synchronous reducer")
        store.send(.increment)
        XCTAssertEqual(store.state.counter, 2)
    }

    // MARK: - Effect pipeline

    @MainActor
    func testSend_effect_feedsFollowupActionThroughReducer() async {
        let store = Store(
            initialState: TestState(),
            environment: TestEnvironment(yield: 42),
            reduce: Self.makeReducer()
        )
        let effectLanded = XCTestExpectation(description: "effect produced a follow-up action")
        var cancellables = Set<AnyCancellable>()
        store.$state
            .dropFirst()
            .sink { state in
                if state.counter == 42 { effectLanded.fulfill() }
            }
            .store(in: &cancellables)

        store.send(.triggerEffect)

        // 5s budget covers the unstructured-Task hop back to @MainActor +
        // suite-wide dispatch saturation. Earlier 1s flaked under load.
        await fulfillment(of: [effectLanded], timeout: 5.0)
        XCTAssertEqual(store.state.counter, 42,
                       "Effect's .setTo(env.yield) action must flow back through the reducer")
    }

    // MARK: - Awaitable send

    /// `sendAwait(_:)` exists for VM flows that need the effect chain to
    /// complete before the caller returns — e.g. a search filter where the
    /// test and UI both assume visibleBooks has settled before asserting.
    /// Fire-and-forget `send(_:)` can't satisfy that without test-side polling.
    @MainActor
    func testSendAwait_runsEffectChainToCompletionBeforeReturning() async {
        let store = Store(
            initialState: TestState(),
            environment: TestEnvironment(yield: 7),
            reduce: Self.makeReducer()
        )
        await store.sendAwait(.triggerEffect)
        XCTAssertEqual(store.state.counter, 7,
                       "sendAwait must not return until the effect's follow-up action has been reduced")
    }

    // MARK: - Environment injection

    @MainActor
    func testEnvironment_substitution_changesEffectOutput() async {
        let alternate = Store(
            initialState: TestState(),
            environment: TestEnvironment(yield: 999),
            reduce: Self.makeReducer()
        )
        let exp = XCTestExpectation(description: "alternate environment reflected in effect")
        var cancellables = Set<AnyCancellable>()
        alternate.$state
            .dropFirst()
            .sink { if $0.counter == 999 { exp.fulfill() } }
            .store(in: &cancellables)

        alternate.send(.triggerEffect)
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(alternate.state.counter, 999,
                       "Different Environment values must produce different effect outputs — that's the whole point of injection")
    }
}
