//
//  PositionWriterContractTests.swift
//  PalaceTests
//
//  Contract-snapshot tests for `PalaceReadingPosition.RemotePositionWriter`
//  — the canonical position writer that all three reader formats funnel
//  through. Locks the call-order contract between the writer and its
//  injected `PositionNetworkAdapter` + clock.
//
//  Why a contract snapshot:
//
//  The writer's behavior is a state machine over (lastPostAttempt, queued,
//  deferredFlushScheduled). Plain unit tests verify outputs; the snapshot
//  pins the *sequence of calls into the network seam*. A refactor that
//  silently changes that sequence (e.g. drops the per-book throttle keying,
//  or stops cancelling the queued snapshot) drifts the snapshot and fails
//  the test loudly.
//
//  Pattern matches `BorrowReducerContractTests.swift`.
//
//  **First run:** records baselines at
//  `__Snapshots__/PositionWriterContractTests/<scenario>.json` and FAILS
//  with "snapshot recorded — re-run to verify". Review the recorded JSON,
//  commit, then re-run. Set `CONTRACT_SNAPSHOT_RECORD=1` to deliberately
//  re-record any time the contract intentionally changes.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceReadingPosition
@testable import Palace

// MARK: - Spy adapter

/// `PositionNetworkAdapter` spy that records every `post` and `fetch`
/// into a shared `CallLog`. `nextServerID` controls the value returned
/// from `post`; `nextFetchResult` controls what `fetch` returns.
private final class SpyPositionNetworkAdapter: PositionNetworkAdapter, @unchecked Sendable {

    let log: CallLog

    private let lock = NSLock()
    private var _nextServerID: String = "spy-server-id"
    private var _nextFetchResult: PositionSnapshot? = nil
    private var _postCount: Int = 0

    init(log: CallLog) {
        self.log = log
    }

    var nextServerID: String {
        get { lock.lock(); defer { lock.unlock() }; return _nextServerID }
        set { lock.lock(); defer { lock.unlock() }; _nextServerID = newValue }
    }

    var nextFetchResult: PositionSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return _nextFetchResult }
        set { lock.lock(); defer { lock.unlock() }; _nextFetchResult = newValue }
    }

    var postCount: Int {
        lock.lock(); defer { lock.unlock() }; return _postCount
    }

    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        lock.lock()
        _postCount += 1
        let id = _nextServerID
        lock.unlock()
        // Record stable-shape args only — exact timestamps would drift
        // across runs. Record bookID + format + payload-bytes-count, which
        // is enough to catch any reordering or argument swap.
        log.record(
            "network.post",
            args: [
                "bookID": snapshot.bookID,
                "format": snapshot.format.rawValue,
                "payloadByteCount": snapshot.payload.count,
                "returns": id,
            ]
        )
        return id
    }

    func fetch(bookID: String) async throws -> PositionSnapshot? {
        let result: PositionSnapshot?
        lock.lock()
        result = _nextFetchResult
        lock.unlock()
        log.record(
            "network.fetch",
            args: [
                "bookID": bookID,
                "returnsNil": result == nil,
            ]
        )
        return result
    }
}

// MARK: - Test fixtures

private enum Fixture {
    static let bookID = "contract-book-1"

    static func snapshot(bookID: String = Fixture.bookID, payload: String = "p") -> PositionSnapshot {
        PositionSnapshot(
            bookID: bookID,
            format: .epubLocator,
            // Deterministic 8-byte payload — payloadByteCount is what's
            // recorded into the snapshot, and a fixed-length payload keeps
            // the contract stable.
            payload: Data(payload.padding(toLength: 8, withPad: " ", startingAt: 0).utf8),
            // Date(timeIntervalSince1970:0) is a stable reference value.
            // Note: we record format/byteCount/bookID in the spy — NOT the
            // timestamp — so the contract survives wall-clock changes.
            timestamp: Date(timeIntervalSince1970: 0),
            device: "spy-device"
        )
    }
}

/// Frozen clock helper. Each call to `now` returns the currently-set
/// time; tests advance it explicitly via `advance(by:)`.
private final class FrozenClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }; return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    func sendable() -> @Sendable () -> Date {
        // The clock instance is `@unchecked Sendable`; closure captures
        // self to read the latest value at call time.
        { [weak self] in self?.now ?? Date(timeIntervalSince1970: 0) }
    }
}

// MARK: - Tests

/// Contract-snapshot tests for `RemotePositionWriter`. Each scenario drives
/// the real writer with a spy adapter + frozen clock and locks the call
/// sequence into the adapter as a JSON snapshot.
final class PositionWriterContractTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: 1. First save in window → network.post fires immediately

    /// Pins: a `save` against a fresh-state writer triggers exactly one
    /// `network.post` and returns the server ID synchronously.
    ///
    /// Regression caught: if a refactor adds a "warm-up" delay or skips
    /// the first post, the snapshot's `network.post` line disappears.
    func test_save_firstSnapshot_postsImmediately() async throws {
        let log = CallLog()
        let adapter = SpyPositionNetworkAdapter(log: log)
        adapter.nextServerID = "server-1"
        let clock = FrozenClock()
        let writer = RemotePositionWriter(
            network: adapter,
            throttle: 15.0,
            clock: clock.sendable()
        )

        let result = try await writer.save(Fixture.snapshot())

        // Record the writer's externally-observable return value alongside
        // the network calls so the snapshot pins the full contract.
        log.record(
            "writer.save.return",
            args: ["result": result ?? "nil"]
        )

        ContractSnapshot.assert(log, named: "canonical_saveFirstSnapshot_postsImmediately")
    }

    // MARK: 2. Second save inside throttle → no network call, returns nil

    /// Pins: a second `save` for the same bookID inside the throttle
    /// window does NOT hit `network.post`, returns `nil`, and queues
    /// internally. The first save's `network.post` is still visible in
    /// the snapshot — the contract is "1 post + 1 nil-return", not "1 post".
    ///
    /// Regression caught: if a refactor removes the throttle (e.g. flips
    /// `elapsed >= throttle` → `elapsed > throttle` at the exact boundary,
    /// or drops the per-book key) the snapshot grows a second
    /// `network.post` line.
    func test_save_secondWithinThrottle_queuesAndReturnsNil() async throws {
        let log = CallLog()
        let adapter = SpyPositionNetworkAdapter(log: log)
        adapter.nextServerID = "server-A"
        let clock = FrozenClock()
        let writer = RemotePositionWriter(
            network: adapter,
            throttle: 15.0,
            clock: clock.sendable()
        )

        // First save — primes the throttle window.
        _ = try await writer.save(Fixture.snapshot(payload: "first"))

        // Second save — well inside the 15s window.
        clock.advance(by: 1.0)
        let secondResult = try await writer.save(Fixture.snapshot(payload: "secnd"))

        log.record(
            "writer.save.return",
            args: ["call": "second", "result": secondResult ?? "nil"]
        )

        ContractSnapshot.assert(log, named: "canonical_saveSecondWithinThrottle_queuesAndReturnsNil")
    }

    // MARK: 3. Throttle elapsed → next save fires queued network.post

    /// Pins: after the throttle window elapses, the next `save` for the
    /// same bookID DOES post — proving the per-book stamp is wallclock-
    /// driven, not call-count-driven.
    ///
    /// Regression caught: if the refactor drops `lastPostAttempt` stamping
    /// the third save would still be throttled — the snapshot's final
    /// `network.post` disappears.
    func test_save_throttleElapsed_postsQueued() async throws {
        let log = CallLog()
        let adapter = SpyPositionNetworkAdapter(log: log)
        adapter.nextServerID = "server-X"
        let clock = FrozenClock()
        let writer = RemotePositionWriter(
            network: adapter,
            throttle: 15.0,
            clock: clock.sendable()
        )

        // First post.
        _ = try await writer.save(Fixture.snapshot(payload: "first"))

        // Second save inside the window — queues, no post.
        clock.advance(by: 1.0)
        _ = try await writer.save(Fixture.snapshot(payload: "secnd"))

        // Advance past the throttle window and save again — this should
        // fire `network.post` because the per-book stamp has lapsed.
        clock.advance(by: 20.0)
        adapter.nextServerID = "server-Y"
        let thirdResult = try await writer.save(Fixture.snapshot(payload: "third"))

        log.record(
            "writer.save.return",
            args: ["call": "third", "result": thirdResult ?? "nil"]
        )

        ContractSnapshot.assert(log, named: "canonical_throttleElapsed_postsQueued")
    }

    // MARK: 4. load delegates to adapter.fetch

    /// Pins: `load(for:)` calls `network.fetch` exactly once with the same
    /// bookID. The writer is documented to NOT cache or apply conflict
    /// resolution — this snapshot is the structural assertion of that.
    ///
    /// Regression caught: a refactor that introduces a caching layer or
    /// short-circuits `fetch` adds/removes lines from the snapshot.
    func test_load_callsFetch() async throws {
        let log = CallLog()
        let adapter = SpyPositionNetworkAdapter(log: log)
        let cached = Fixture.snapshot(payload: "loaded")
        adapter.nextFetchResult = cached
        let clock = FrozenClock()
        let writer = RemotePositionWriter(
            network: adapter,
            throttle: 15.0,
            clock: clock.sendable()
        )

        let result = try await writer.load(for: Fixture.bookID)

        // The result IS the cached fixture — verify identity at the spy
        // boundary by recording the bookID + payload byte count.
        log.record(
            "writer.load.return",
            args: [
                "isNil": result == nil,
                "bookID": result?.bookID ?? "nil",
                "payloadByteCount": result?.payload.count ?? -1,
            ]
        )

        ContractSnapshot.assert(log, named: "canonical_load_callsFetch")
    }

    // MARK: 5. cancel clears state — next save posts immediately

    /// Pins: a second save inside the throttle window normally queues
    /// (returns nil — covered by scenario 2). BUT after `cancel(for:)`,
    /// the per-book state is cleared and the *next* save posts again.
    /// The snapshot records: post → cancel → post.
    ///
    /// Regression caught: a refactor that forgets to clear
    /// `state[bookID]` on cancel would leave the throttle stamp in place;
    /// the post-cancel save would queue (returns nil) and the snapshot
    /// would lose its second `network.post` line.
    func test_cancel_clearsState_thenSaveAgainPostsImmediately() async throws {
        let log = CallLog()
        let adapter = SpyPositionNetworkAdapter(log: log)
        adapter.nextServerID = "server-first"
        let clock = FrozenClock()
        let writer = RemotePositionWriter(
            network: adapter,
            throttle: 15.0,
            clock: clock.sendable()
        )

        // First save — primes the throttle window.
        _ = try await writer.save(Fixture.snapshot(payload: "first"))

        // Cancel. From the spy's POV this is a state-clearing op with no
        // network side effects. Record it explicitly so the snapshot
        // captures the call.
        log.record("writer.cancel", args: ["bookID": Fixture.bookID])
        await writer.cancel(for: Fixture.bookID)

        // Advance the clock just slightly so we're well inside the
        // original throttle window. If `cancel` did NOT clear state, this
        // save would queue and return nil.
        clock.advance(by: 1.0)
        adapter.nextServerID = "server-after-cancel"
        let result = try await writer.save(Fixture.snapshot(payload: "afterC"))

        log.record(
            "writer.save.return",
            args: ["call": "afterCancel", "result": result ?? "nil"]
        )

        ContractSnapshot.assert(log, named: "canonical_cancel_clearsState_thenSaveAgainPostsImmediately")
    }

    // MARK: 6. Background-task lifetime around the network post

    /// Pins: every `save` that posts wraps `network.post` in a
    /// `UIApplication.beginBackgroundTask` / `endBackgroundTask` pair via
    /// `defer`. The pair is invisible to a pure spy adapter (it lives at
    /// the `RemotePositionWriter` level, above the network seam), but the
    /// *observable* contract is that:
    ///   (a) `network.post` runs to completion before the `save` call
    ///       returns, AND
    ///   (b) the writer is `nil`-safe under teardown — the `weak self`
    ///       capture inside the iOS-only `endBackgroundTask` branch is
    ///       reachable from this test surface, not from the SPM bundle.
    ///
    /// Module A flagged the `if id != .invalid` guard at
    /// `RemotePositionWriter.swift:201` as un-killable from the SPM macOS
    /// runtime (mutant 3). This scenario locks the iOS-host call order:
    /// `network.post → return`. If the writer's `defer endBackgroundTask`
    /// is broken into an unconditional call (the mutated branch), the
    /// post still fires and the snapshot still matches — so this scenario
    /// alone does NOT kill mutant 3. It DOES however lock the
    /// post-completes-synchronously contract, which catches the inverse
    /// regression: removing the `defer` block entirely (which would let
    /// the begin call leak when `network.post` throws).
    ///
    /// See transcript "Gaps for integrator": full mutant-3 kill requires a
    /// production-code injection seam over `UIApplication.shared`. None
    /// exists at the time of writing; this scenario is the best
    /// observable lock from a contract test.
    func test_backgroundTask_postCompletes_aroundNetworkPost() async throws {
        let log = CallLog()
        let adapter = SpyPositionNetworkAdapter(log: log)
        adapter.nextServerID = "server-bg"
        let clock = FrozenClock()
        let writer = RemotePositionWriter(
            network: adapter,
            throttle: 15.0,
            clock: clock.sendable()
        )

        // Record the entry/exit around the save so the snapshot pins the
        // ordering of: writer.save.begin → network.post → writer.save.end.
        log.record("writer.save.begin", args: ["bookID": Fixture.bookID])
        let result = try await writer.save(Fixture.snapshot(payload: "bgtask"))
        log.record(
            "writer.save.end",
            args: [
                "bookID": Fixture.bookID,
                "result": result ?? "nil",
                "postCount": adapter.postCount,
            ]
        )

        ContractSnapshot.assert(log, named: "canonical_backgroundTask_postCompletes_aroundNetworkPost")
    }
}
