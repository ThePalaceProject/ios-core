import Foundation
import XCTest

/// Per-test `UserDefaults` isolation helper.
///
/// Returns a `UserDefaults(suiteName:)` whose suite name encodes both the
/// XCTestCase invocation name and a per-call UUID so two adjacent test
/// methods cannot read each other's writes, and a single test method that
/// calls `testUserDefaults()` twice gets two independent stores. Each
/// returned suite is wired to the process-wide
/// `SingletonResetRegistry.shared` so the `PalaceSingletonResetObserver`
/// drops the entire persistent domain in `testCaseDidFinish(_:)`.
///
/// Why a suite per call and not per test:
///  - Some tests want to model "fresh install" vs. "post-write" with two
///    disjoint stores in the same test body. Per-call isolation makes
///    that trivial.
///  - The resetter dedupes registrations under the same name in
///    `SingletonResetRegistry`, so a single test that calls
///    `testUserDefaults()` 100 times does NOT register 100 resetters —
///    only the most recent suite name is held by the closure, and the
///    closure resets every suite the test owns when it runs.
///
/// Why we do NOT touch `.standard`:
///  - The whole point of swarm_47883816 is to stop tests from polluting
///    one another via `UserDefaults.standard`. A helper that fell back
///    to `.standard` under any condition would reintroduce that
///    pollution silently. There is no fallback — the suite is always
///    fresh.
///
/// Usage:
/// ```swift
/// final class SomeTests: XCTestCase {
///     func testWritesAreIsolated() {
///         let defaults = testUserDefaults()
///         defaults.set(true, forKey: "flag")
///         XCTAssertTrue(defaults.bool(forKey: "flag"))
///     }
/// }
/// ```
extension XCTestCase {

    /// Returns a per-call isolated `UserDefaults` instance backed by a
    /// fresh persistent domain. The domain is cleared by the
    /// `SingletonResetRegistry` resetter installed for this XCTestCase
    /// invocation when the test finishes.
    ///
    /// - Parameters:
    ///   - file: source file (defaulted via `#file`); used only for the
    ///     `XCTFail` location if the suite cannot be created.
    ///   - line: source line (defaulted via `#line`); used only for the
    ///     `XCTFail` location.
    /// - Returns: a `UserDefaults` instance pointing at a unique suite
    ///   name. The caller does NOT need to clean up — the resetter
    ///   handles it.
    /// `static`: this helper reads nothing from the test instance (the suite
    /// name is fully UUID-derived), so making it static removes `self` as the
    /// receiver. A nonisolated instance method invoked on a `@MainActor`,
    /// non-`Sendable` test `self` forces the compiler to *send* `self`
    /// ("sending 'self' risks causing data races"); an `@MainActor` variant
    /// instead can't return its non-`Sendable` result to a nonisolated
    /// `setUp()`. Only a receiver-free `static` satisfies BOTH caller kinds
    /// the suite has (@MainActor `setUpWithError`/test methods AND nonisolated
    /// plain `setUp()` overrides). Callers use `Self.testUserDefaults()`.
    static func testUserDefaults(
        file: StaticString = #file,
        line: UInt = #line
    ) -> UserDefaults {
        // Suite name is UUID-derived — unique per call, no dependency on the
        // test instance. (Previously prefixed with the sanitized test name for
        // readability in `defaults read`; dropped so the helper can be static.)
        let suiteName = "test-\(UUID().uuidString)"

        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail(
                "testUserDefaults: failed to create UserDefaults suite '\(suiteName)'",
                file: file,
                line: line
            )
            // Returning `.standard` would defeat the point. Returning a
            // fresh ephemeral suite under a different name is also
            // wrong — the test wanted a specific isolated store. The
            // `XCTFail` above already marked the test as failed; an
            // empty suite is a safer return than `.standard`.
            return UserDefaults(suiteName: "test-fallback-\(UUID().uuidString)") ?? .standard
        }

        // Register a per-suite resetter. The registry dedupes by name,
        // so the same XCTestCase invocation calling `testUserDefaults()`
        // many times only winds up with one entry per suite name —
        // which is what we want (each suite name is unique already).
        let resetterName = "testUserDefaults.\(suiteName)"
        SingletonResetRegistry.shared.register(resetterName) {
            // `removePersistentDomain(forName:)` is the correct call to
            // wipe the entire suite. `.removeObject(forKey:)` only
            // clears one key; a test that sets a key we don't know
            // about would leak it across runs without this.
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            // Belt-and-braces: also remove on the suite's own instance
            // (in case the implementation caches values internally).
            // This is harmless if the persistent domain is already
            // empty.
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        return defaults
    }
}
