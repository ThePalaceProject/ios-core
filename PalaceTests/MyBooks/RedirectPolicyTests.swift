//
//  RedirectPolicyTests.swift
//  PalaceTests
//
//  Covers the willPerformHTTPRedirection decision lifted out of MBDC:
//    - cap at maxRedirectAttempts (deny once reached)
//    - HTTPS → non-HTTPS downgrade rejection
//    - increment counter on every accepted decision
//    - allow normal redirects (HTTP→HTTP, HTTPS→HTTPS, HTTP→HTTPS)
//

import XCTest
@testable import Palace

// Deliberately NOT @MainActor: the object under test is nonisolated and
// non-Sendable — awaiting its async APIs on a @MainActor-held reference is a
// Swift 6 sending error, while from a nonisolated test everything stays in
// one isolation domain. Nothing here touches UI or main-actor state.
final class RedirectPolicyTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a closure-driven RedirectPolicy whose counters are backed
    /// by a lock-guarded dictionary so tests can arrange / observe attempts
    /// without standing up the real DownloadCoordinator actor.
    ///
    /// Swift 6: `RedirectPolicy` is now `Sendable` (its closures are
    /// `@Sendable`), so the store those closures capture must be `Sendable`
    /// too. Every access goes through `lock`, so `@unchecked Sendable` is sound
    /// (the same idiom as `LockIsolated`). `attempts` is exposed via a
    /// lock-guarded computed shim so the tests' `store.attempts[42] = 10`
    /// arrange lines and `store.incrementCalls` assertions stay unchanged.
    private final class CounterStore: @unchecked Sendable {
        private let lock = NSLock()
        private var _attempts: [Int: Int] = [:]
        private var _incrementCalls: [Int] = []

        var attempts: [Int: Int] {
            get { lock.withLock { _attempts } }
            set { lock.withLock { _attempts = newValue } }
        }
        var incrementCalls: [Int] { lock.withLock { _incrementCalls } }

        func get(_ taskID: Int) -> Int { lock.withLock { _attempts[taskID] ?? 0 } }
        func increment(_ taskID: Int) {
            lock.withLock {
                _incrementCalls.append(taskID)
                _attempts[taskID, default: 0] += 1
            }
        }
    }

    private func makePolicy(store: CounterStore, max: Int = 10) -> RedirectPolicy {
        RedirectPolicy(
            getRedirectAttempts: { id in store.get(id) },
            incrementRedirectAttempts: { id in store.increment(id) },
            maxRedirectAttempts: max
        )
    }

    private func request(_ urlString: String) -> URLRequest {
        URLRequest(url: URL(string: urlString)!)
    }

    // MARK: - Cap behavior

    func testDecide_AtMaxAttempts_ReturnsNilAndDoesNotIncrement() async {
        let store = CounterStore()
        store.attempts[42] = 10
        let policy = makePolicy(store: store, max: 10)

        let result = await policy.decide(
            taskIdentifier: 42,
            originalScheme: "https",
            newRequest: request("https://example.com/next")
        )

        XCTAssertNil(result, "Reaching the cap must deny further redirects")
        XCTAssertTrue(store.incrementCalls.isEmpty, "Increment must NOT fire once the cap has been reached")
    }

    func testDecide_OneBelowMax_AllowsAndIncrements() async {
        let store = CounterStore()
        store.attempts[42] = 9
        let policy = makePolicy(store: store, max: 10)

        let result = await policy.decide(
            taskIdentifier: 42,
            originalScheme: "https",
            newRequest: request("https://example.com/next")
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(store.incrementCalls, [42])
        XCTAssertEqual(store.attempts[42], 10, "9 → 10 transition should land")
    }

    func testDecide_AboveMax_StillReturnsNil() async {
        let store = CounterStore()
        store.attempts[42] = 999
        let policy = makePolicy(store: store, max: 10)

        let result = await policy.decide(
            taskIdentifier: 42,
            originalScheme: "https",
            newRequest: request("https://example.com/next")
        )

        XCTAssertNil(result, "`>=` not `==` — well past the cap must still deny")
    }

    // MARK: - HTTPS downgrade rejection

    func testDecide_HTTPSToHTTP_ReturnsNilButHasIncremented() async {
        let store = CounterStore()
        let policy = makePolicy(store: store)

        let result = await policy.decide(
            taskIdentifier: 1,
            originalScheme: "https",
            newRequest: request("http://attacker.example/next")
        )

        XCTAssertNil(result, "HTTPS → HTTP downgrade must be denied")
        // The counter increments BEFORE the scheme check by design — that's
        // how MBDC's old behavior counted "attempts considered", not just
        // "attempts followed". Lock that in so a later refactor doesn't
        // silently shift counter semantics.
        XCTAssertEqual(store.incrementCalls, [1])
    }

    func testDecide_HTTPSToHTTPS_Allowed() async {
        let store = CounterStore()
        let policy = makePolicy(store: store)

        let result = await policy.decide(
            taskIdentifier: 1,
            originalScheme: "https",
            newRequest: request("https://other.example/next")
        )

        XCTAssertEqual(result?.url?.absoluteString, "https://other.example/next")
    }

    func testDecide_HTTPToAnything_NotADowngrade() async {
        let store = CounterStore()
        let policy = makePolicy(store: store)

        let toHTTP = await policy.decide(
            taskIdentifier: 1,
            originalScheme: "http",
            newRequest: request("http://example.com/next")
        )
        XCTAssertNotNil(toHTTP, "HTTP → HTTP should not be denied as a downgrade")

        let toHTTPS = await policy.decide(
            taskIdentifier: 2,
            originalScheme: "http",
            newRequest: request("https://example.com/next")
        )
        XCTAssertNotNil(toHTTPS, "HTTP → HTTPS upgrade is fine")
    }

    func testDecide_NilOriginalScheme_NotTreatedAsDowngrade() async {
        let store = CounterStore()
        let policy = makePolicy(store: store)

        // Original scheme nil shouldn't match the "https && !https" guard,
        // so the redirect is allowed.
        let result = await policy.decide(
            taskIdentifier: 1,
            originalScheme: nil,
            newRequest: request("http://example.com/next")
        )

        XCTAssertNotNil(result)
    }

    // MARK: - Per-task isolation

    func testDecide_CounterIsPerTask() async {
        let store = CounterStore()
        store.attempts[1] = 10
        // Task 1 is at cap; task 2 must still be allowed to redirect.
        let policy = makePolicy(store: store, max: 10)

        let task1 = await policy.decide(
            taskIdentifier: 1,
            originalScheme: "https",
            newRequest: request("https://example.com/x")
        )
        let task2 = await policy.decide(
            taskIdentifier: 2,
            originalScheme: "https",
            newRequest: request("https://example.com/y")
        )

        XCTAssertNil(task1, "task 1 capped")
        XCTAssertNotNil(task2, "task 2 still under its own cap")
        XCTAssertEqual(store.incrementCalls, [2])
    }

    // MARK: - Custom max

    func testDecide_CustomMaxAttempts_Honored() async {
        let store = CounterStore()
        store.attempts[1] = 2
        let policy = makePolicy(store: store, max: 2)

        let result = await policy.decide(
            taskIdentifier: 1,
            originalScheme: "https",
            newRequest: request("https://example.com/next")
        )

        XCTAssertNil(result, "Custom max=2 + attempts=2 must deny")
    }
}
