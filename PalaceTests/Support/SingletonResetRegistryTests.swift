import Foundation
import XCTest
@testable import Palace

/// Tests for `SingletonResetRegistry` — the test-target-only resetter registry
/// invoked by `PalaceSingletonResetObserver.testCaseDidFinish(_:)` after every
/// test. The registry is process-wide; every test in this class drains the
/// registry via `_removeAllForTests()` in `setUp` so the suite's built-in
/// resetters do not leak into these assertions and vice-versa.
final class SingletonResetRegistryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SingletonResetRegistry.shared._removeAllForTests()
    }

    override func tearDown() {
        SingletonResetRegistry.shared._removeAllForTests()
        super.tearDown()
    }

    // MARK: - 1. Registration order = invocation order, and invocation is idempotent

    func testRegister_thenInvokeAll_callsResettersInRegistrationOrder() {
        let registry = SingletonResetRegistry.shared
        var calls: [String] = []

        registry.register("A") { calls.append("A") }
        registry.register("B") { calls.append("B") }
        registry.register("C") { calls.append("C") }

        registry.invokeAll()
        XCTAssertEqual(calls, ["A", "B", "C"], "Invocation order must match registration order on first invoke")

        // Idempotent invocation: invoking again drives the SAME closures again
        // in the SAME order — proves the registry is not consumed on iteration.
        registry.invokeAll()
        XCTAssertEqual(calls, ["A", "B", "C", "A", "B", "C"], "Second invokeAll() must drive the same resetters again")
    }

    // MARK: - 2. Re-registering a name overwrites in place, preserving order

    func testRegister_reRegisterSameName_overwritesInPlacePreservingOrder() {
        let registry = SingletonResetRegistry.shared
        var calls: [String] = []

        registry.register("A") { calls.append("A") }
        registry.register("B") { calls.append("B") }
        registry.register("C") { calls.append("C") }

        // Re-register B with a new closure. The contract says the position in
        // the iteration order is preserved; only the closure swaps.
        registry.register("B") { calls.append("B-v2") }

        XCTAssertEqual(
            registry.registeredNames(), ["A", "B", "C"],
            "Re-registering B must not move it to the end"
        )

        registry.invokeAll()
        XCTAssertEqual(
            calls, ["A", "B-v2", "C"],
            "The replaced closure must fire in B's original position"
        )
    }

    // MARK: - 3. Reentrant register-during-iteration is dropped

    func testInvokeAll_reentrantRegisterDuringResetter_isDroppedWithWarning() {
        let registry = SingletonResetRegistry.shared
        var calls: [String] = []

        // A's closure attempts to register "X" mid-iteration. Contract: dropped.
        registry.register("A") {
            calls.append("A")
            registry.register("X") { calls.append("X") }
        }
        registry.register("B") { calls.append("B") }

        registry.invokeAll()

        XCTAssertEqual(calls, ["A", "B"], "X must not have been invoked — reentrant registration dropped")
        XCTAssertEqual(
            registry.registeredNames(), ["A", "B"],
            "Post-invoke snapshot must NOT contain X (reentrant register was dropped)"
        )
    }

    // MARK: - 4. Resetter capturing a nil weak-ref does not crash

    func testInvokeAll_resetterClosureCapturingNilWeakRef_doesNotCrash() {
        let registry = SingletonResetRegistry.shared

        // Allocate a holder, capture weak, drop strong reference, then invoke.
        // The closure must tolerate a nil weak ref without crashing — pinning
        // the "nil-safe" property in the contract docblock.
        final class Holder { var hits = 0 }
        weak var weakHolder: Holder?
        do {
            let holder = Holder()
            weakHolder = holder
            registry.register("nilSafe") { [weak holder] in
                // Optional chain — must not crash if `holder` is nil.
                holder?.hits += 1
            }
            _ = holder // keep holder alive in this do-block scope
        }
        // After the do-block, `holder` is deallocated; weakHolder is nil.
        XCTAssertNil(weakHolder, "Precondition: the captured weak ref must be nil at invoke time")

        // The bar is "does not crash"; we cannot meaningfully assert beyond
        // "the test process did not terminate." A test method that returns
        // normally satisfies the contract.
        registry.invokeAll()
    }

    // MARK: - 5. Concurrent register from multiple threads is consistent

    func testRegister_multipleThreadsConcurrently_yieldsConsistentSnapshot() {
        let registry = SingletonResetRegistry.shared
        let threadCount = 4
        let perThread = 100
        let group = DispatchGroup()

        for threadIndex in 0..<threadCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for j in 0..<perThread {
                    registry.register("thread-\(threadIndex)-reset-\(j)") {}
                }
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(result, .success, "Concurrent register must not deadlock")

        let names = registry.registeredNames()
        XCTAssertEqual(
            names.count, threadCount * perThread,
            "Every concurrent register call must persist (no lost updates)"
        )
        XCTAssertEqual(
            Set(names).count, names.count,
            "Every name was unique by construction; no duplicates may appear post-register"
        )
    }
}
