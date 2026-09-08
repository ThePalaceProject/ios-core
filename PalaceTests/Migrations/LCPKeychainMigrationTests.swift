//
//  LCPKeychainMigrationTests.swift
//  PalaceTests
//
//  Verifies the one-time gating contract of the LCP SQLite→Keychain
//  migration: it runs once when unflagged, skips when already done, and
//  leaves the flag unset on failure so the next launch retries. The actual
//  Readium repository copy is injected so these tests never touch the real
//  Keychain.
//

#if LCP

import XCTest
@testable import Palace

// Deliberately NOT @MainActor: `LCPKeychainMigration.runIfNeeded` is a
// nonisolated async API taking a (non-Sendable) UserDefaults and non-Sendable
// closures — driving it from a @MainActor test is a Swift 6 sending error,
// while from a nonisolated test everything stays in one isolation domain.
// Nothing here touches UI or main-actor state.
final class LCPKeychainMigrationTests: XCTestCase {

    private let suiteName = "LCPKeychainMigrationTests.suite"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRunIfNeeded_whenFlagUnset_runsMigrationAndSetsFlag() async {
        let ran = LockIsolated<Bool>(false)
        let localDefaults = UserDefaults(suiteName: suiteName)!

        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in ran.value = true })

        XCTAssertTrue(ran.value, "Migration work must run when the flag is unset")
        XCTAssertTrue(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                      "Flag must be set after a successful migration")
    }

    func testRunIfNeeded_whenFlagAlreadySet_skipsMigration() async {
        defaults.set(true, forKey: LCPKeychainMigration.didMigrateKey)
        let ran = LockIsolated<Bool>(false)
        let localDefaults = UserDefaults(suiteName: suiteName)!

        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in ran.value = true })

        XCTAssertFalse(ran.value, "Migration work must NOT run once the flag is set")
    }

    // MARK: - Concurrent callers (PP-5091)

    /// Two callers can be in `runIfNeeded` at once. `TPPMigrationManager.migrate`
    /// starts one without awaiting it, so two calls to `migrate` overlap. The flag
    /// is written only *after* the copy finishes, so before this guard existed both
    /// callers cleared the gate and both copied.
    ///
    /// The observing defaults are what stop this test from being vacuous: a second
    /// caller that arrives *after* the first finished takes the already-migrated
    /// fast path, and "migrated once" would then be true for the wrong reason. The
    /// assertion on the observed gate value proves the second caller looked while
    /// the gate was still open.
    ///
    /// It asserts the copy COUNT and nothing about ordering. An earlier version of
    /// this file also asserted that the second caller returned only after the first
    /// had finished; that assertion was green by construction under the fix and
    /// only *racily* red under the mutant, because the test opens the release gate
    /// concurrently with the second caller's return and cannot order the two. A
    /// test that cannot force the interleaving it asserts is not evidence.
    func testRunIfNeeded_whenASecondCallerArrivesMidCopy_migratesAtMostOnce() async {
        let copies = LockIsolated<Int>(0)
        let firstCallerIsCopying = AsyncGate()
        let releaseFirstCaller = AsyncGate()
        let secondCallerReadTheGate = AsyncGate()
        let gateValuesSeenAfterCopyBegan = LockIsolated<[Bool]>([])

        let defaults = GateObservingDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let first = Task {
            await LCPKeychainMigration.runIfNeeded(defaults: defaults, migrate: { @Sendable in
                copies.withValue { $0 += 1 }
                await firstCallerIsCopying.open()
                await releaseFirstCaller.wait("releaseFirstCaller")
            })
        }
        // The first caller has finished every gate read it will make and is now
        // parked inside the copy, so from here any read belongs to the second.
        await firstCallerIsCopying.wait("firstCallerIsCopying")

        defaults.observeMigrationFlagReads { value in
            gateValuesSeenAfterCopyBegan.withValue { $0.append(value) }
            Task { await secondCallerReadTheGate.open() }
        }

        let second = Task {
            await LCPKeychainMigration.runIfNeeded(defaults: defaults, migrate: { @Sendable in
                copies.withValue { $0 += 1 }
            })
        }
        await secondCallerReadTheGate.wait("secondCallerReadTheGate")

        XCTAssertEqual(gateValuesSeenAfterCopyBegan.value.first, false,
                       "The second caller must have read the gate while it was still open — otherwise it took the already-migrated fast path and this test proves nothing")

        await releaseFirstCaller.open()
        await first.value
        await second.value

        XCTAssertEqual(copies.value, 1,
                       "Two callers racing an unwritten flag must share one migration, not run two concurrent Keychain copies")
        XCTAssertTrue(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                      "The shared migration still has to set the flag")
    }

    // MARK: - Partial failure

    /// The production copy is two writes — licenses, then passphrases — and the
    /// second can fail after the first has already landed. Readium's `migrate(to:)`
    /// is idempotent, so the correct response is to leave the half-copied state
    /// alone, leave the flag unset, and finish the job next launch.
    ///
    /// What this adds over `..._leavesFlagUnsetAndRetriesNextTime` is the far end:
    /// a retry that SUCCEEDS after a partial failure must set the flag. Nothing
    /// covered that, and a migration that can never mark itself done re-runs the
    /// whole copy on every launch forever.
    func testRunIfNeeded_whenARetryAfterAPartialFailureSucceeds_setsTheFlag() async {
        struct PassphraseCopyFailed: Error {}
        let writes = LockIsolated<[String]>([])
        let localDefaults = UserDefaults(suiteName: suiteName)!

        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in
            writes.withValue { $0.append("licenses") }
            throw PassphraseCopyFailed()
        })

        XCTAssertEqual(writes.value, ["licenses"],
                       "A failed migration must not roll back the half that already succeeded")
        XCTAssertFalse(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                       "A partial copy is not a completed migration")

        // Next launch finishes it.
        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in
            writes.withValue { $0.append("licenses") }
            writes.withValue { $0.append("passphrases") }
        })

        XCTAssertEqual(writes.value, ["licenses", "licenses", "passphrases"],
                       "The retry must re-run the whole copy over the partial state")
        XCTAssertTrue(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                      "Only a complete copy sets the flag")
    }

    func testRunIfNeeded_whenMigrationThrows_leavesFlagUnsetAndRetriesNextTime() async {
        struct MigrationError: Error {}
        let attempts = LockIsolated<Int>(0)
        let localDefaults = UserDefaults(suiteName: suiteName)!

        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in
            attempts.value += 1
            throw MigrationError()
        })

        XCTAssertEqual(attempts.value, 1, "Migration should have been attempted once")
        XCTAssertFalse(defaults.bool(forKey: LCPKeychainMigration.didMigrateKey),
                       "Flag must stay unset on failure so the next launch retries")

        // A subsequent launch must retry because the flag is still unset.
        await LCPKeychainMigration.runIfNeeded(defaults: localDefaults, migrate: { @Sendable in
            attempts.value += 1
            throw MigrationError()
        })

        XCTAssertEqual(attempts.value, 2, "An unflagged failed migration must retry on the next run")
    }
}

// MARK: - Test support

/// A `UserDefaults` that reports reads of the migration flag.
///
/// The race tests need to know that the second caller evaluated the gate *while
/// the first was still copying*. Nothing else observes that moment: the gate read
/// happens inside `runIfNeeded` before any suspension point, so a signal placed in
/// the caller's own task body would only prove the task started, not that it got
/// as far as the gate. Without the distinction those tests pass whenever the
/// second caller happens to arrive late, which is the vacuous-green shape.
private final class GateObservingDefaults: UserDefaults, @unchecked Sendable {
    private let observer = LockIsolated<(@Sendable (Bool) -> Void)?>(nil)

    func observeMigrationFlagReads(_ body: @escaping @Sendable (Bool) -> Void) {
        observer.value = body
    }

    override func bool(forKey defaultName: String) -> Bool {
        let value = super.bool(forKey: defaultName)
        if defaultName == LCPKeychainMigration.didMigrateKey {
            observer.value?(value)
        }
        return value
    }
}

/// A one-shot gate. Used instead of `XCTestExpectation` plus a sleep so the race
/// tests are ordered by construction rather than by timing: every "the other
/// caller is definitely here now" step is a real happens-before edge.
private actor AsyncGate {
    private enum State { case closed, opened, timedOut }

    private var state: State = .closed
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() { settle(.opened) }

    private func settle(_ newState: State) {
        guard case .closed = state else { return }
        state = newState
        let resumable = waiters
        waiters = []
        resumable.forEach { $0.resume() }
    }

    /// Waits for the gate, but never forever.
    ///
    /// Every way these tests can go wrong — a caller absorbed into an unrelated
    /// migration, a gate nobody reaches — shows up as a gate that never opens. An
    /// unbounded wait turns all of them into `exceeded execution time allowance`,
    /// which this project treats as a failure but one with no name attached, and
    /// which reads as CI flakiness rather than as this test failing. Bounded, they
    /// fail here, by name, saying which gate stalled.
    func wait(_ label: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return // cancelled: the gate opened normally
            }
            await self.settle(.timedOut)
        }
        defer { deadline.cancel() }

        if case .closed = state {
            await withCheckedContinuation { waiters.append($0) }
        }

        if case .timedOut = state {
            XCTFail("Timed out waiting for gate '\(label)' — the other caller never reached it",
                    file: file, line: line)
        }
    }
}

#endif
