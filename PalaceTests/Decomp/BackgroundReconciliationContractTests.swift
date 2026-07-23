//
//  BackgroundReconciliationContractTests.swift
//  PalaceTests
//
//  PRE-WAVE test pack for the god-class decomposition campaign
//  (docs/architecture/god-class-decomposition-plan.md §3a-3 + §5 row
//  "MyBooksDownloadCenter", Wave 3b → PalaceDownloads).
//
//  Pins the Reliability WS-A launch-reconciliation contract (INV-4:
//  "adopt, don't double-start or spuriously fail") on the PURE engine that
//  owns it — `DownloadReconciliation` in
//  `Palace/MyBooks/DownloadTaskPersistence.swift`. When the WS-A reconciler
//  is lifted into `PalaceDownloads` as `BackgroundSessionReconciler`, this
//  pack must pass byte-identically after the move (the general §5 contract).
//
//  WHY the pure engine (not MBDC): MBDC's `reconcileDownloadsAtLaunch()` is a
//  thin adapter — it snapshots live URLSession tasks and forwards to
//  `DownloadReconciliation.runLaunchReconciliation`, which encapsulates BOTH
//  the decision matrix (`reconcile`) AND the ORDER contract
//  (registry-loaded gate → load persisted → live tasks → registry state →
//  apply). Pinning the engine pins the invariant regardless of where the
//  adapter lands. The MBDC-side glue (session.getAllTasks snapshot, the
//  applyReconcileDecision hot-map re-seed) is already exercised by
//  ColdStartResumeIntegrationTests; this pack pins the decision + order logic
//  those integration tests don't lock as a call-sequence.
//
//  Adjacent WS-A invariants already covered by dedicated UNIT suites (NOT
//  re-pinned here to avoid duplication):
//    - INV-6 transient-transfer retry  → PalaceTests/MyBooks/DownloadTransferRetryTests
//    - INV-7 background completion handler + session identity routing
//                                       → PalaceTests/MyBooks/BackgroundSessionRoutingTests
//    - PP-4114 mid-flight network drop  → PalaceTests/MyBooks/MyBooksDownloadCenterOfflineTests
//

import XCTest
@testable import Palace

final class BackgroundReconciliationContractTests: XCTestCase {

    // MARK: - INV-4 decision matrix (pure `reconcile`)
    //
    // The matrix is {live task / dead task} × {per-book registry state} →
    // ReconcileDecision. Each test kills the switch-arm mutant for its class.

    /// INV-4 core: a still-live background task is ALWAYS adopted, never
    /// restarted and never spuriously failed — EVEN when the registry state
    /// would otherwise route to a heal. A mutant that consults registry state
    /// before checking task liveness (reordering the `if liveTaskIdentifiers…`
    /// guard below the switch) would `.markFailed` a download that is actually
    /// still running in the background — the exact double-start / spurious-fail
    /// bug INV-4 exists to prevent.
    func test_reconcile_liveTask_isAdopted_evenWhenRegistrySaysFailed() {
        let decisions = DownloadReconciliation.reconcile(
            persisted: [Self.record("A", task: 42)],
            liveTaskIdentifiers: [42],
            registryStates: ["A": .downloadFailed]   // registry would say "fail"
        )
        XCTAssertEqual(decisions, [.adopt(bookID: "A", taskIdentifier: 42)])
    }

    /// Dead task + registry still wants the content (`.downloading`,
    /// `.downloadNeeded`, `.SAMLStarted`) → `.restart`. A mutant that dropped
    /// any of these three cases would strand the book with a lost background
    /// task and no re-issue.
    func test_reconcile_deadTask_registryWantsContent_restarts() {
        for state: TPPBookState in [.downloading, .downloadNeeded, .SAMLStarted] {
            let decisions = DownloadReconciliation.reconcile(
                persisted: [Self.record("A", task: 7)],
                liveTaskIdentifiers: [],              // task 7 is NOT live
                registryStates: ["A": state]
            )
            XCTAssertEqual(decisions, [.restart(bookID: "A")],
                           "state \(state.stringValue()) must restart a dead download")
        }
    }

    /// Dead task + registry already `.downloadFailed` → `.markFailed` (pin the
    /// terminal state, drop the record). Distinct from `.restart`: a mutant
    /// folding this into the restart arm would re-kick a download the registry
    /// has already given up on, spinning the UI.
    func test_reconcile_deadTask_alreadyFailed_marksFailed() {
        let decisions = DownloadReconciliation.reconcile(
            persisted: [Self.record("A", task: 7)],
            liveTaskIdentifiers: [],
            registryStates: ["A": .downloadFailed]
        )
        XCTAssertEqual(decisions, [.markFailed(bookID: "A")])
    }

    /// Dead task + the book no longer wants this download (completed while
    /// suspended, or returned/unregistered/held) → `.cleanup` (drop the stale
    /// record, no restart, no state mutation). Covers the terminal-success arm
    /// AND the "book moved on" arm AND the no-registry-entry (`.none`) arm — a
    /// mutant that restarted any of these would re-download content the patron
    /// already has or no longer holds.
    func test_reconcile_deadTask_completedOrUnwanted_cleansUp() {
        let cleanupStates: [TPPBookState] = [
            .downloadSuccessful, .used,
            .unregistered, .holding, .returning, .unsupported
        ]
        for state in cleanupStates {
            let decisions = DownloadReconciliation.reconcile(
                persisted: [Self.record("A", task: 7)],
                liveTaskIdentifiers: [],
                registryStates: ["A": state]
            )
            XCTAssertEqual(decisions, [.cleanup(bookID: "A")],
                           "state \(state.stringValue()) must clean up, not restart/fail")
        }

        // No registry entry at all (`.none`) → also cleanup, not a crash / restart.
        let missing = DownloadReconciliation.reconcile(
            persisted: [Self.record("A", task: 7)],
            liveTaskIdentifiers: [],
            registryStates: [:]
        )
        XCTAssertEqual(missing, [.cleanup(bookID: "A")])
    }

    /// Order + multiplicity: reconcile maps 1:1, preserving record order, and
    /// classifies each record independently (one live, one dead-wanted, one
    /// dead-failed). Kills a mutant that returned a single decision or reordered.
    func test_reconcile_mixedBatch_classifiesEachIndependently_inOrder() {
        let decisions = DownloadReconciliation.reconcile(
            persisted: [
                Self.record("live", task: 1),
                Self.record("deadWanted", task: 2),
                Self.record("deadFailed", task: 3)
            ],
            liveTaskIdentifiers: [1],
            registryStates: [
                "live": .downloading,
                "deadWanted": .downloadNeeded,
                "deadFailed": .downloadFailed
            ]
        )
        XCTAssertEqual(decisions, [
            .adopt(bookID: "live", taskIdentifier: 1),
            .restart(bookID: "deadWanted"),
            .markFailed(bookID: "deadFailed")
        ])
    }

    // MARK: - INV-4 launch ORDER contract (`runLaunchReconciliation`)
    //
    // The order is the invariant: the registry-loaded gate MUST be first
    // (never reconcile against an unloaded registry), the empty-persisted
    // short-circuit MUST precede the (async, potentially expensive) live-task
    // query, and per-book registry reads MUST precede apply. A contract
    // snapshot pins the exact call sequence so an extraction that reorders the
    // steps drifts loudly.

    /// Happy path: gate(true) → loadPersisted(1 dead-wanted record) →
    /// liveTaskIdentifiers → registryState(book) → apply(.restart). The
    /// snapshot locks this five-step order.
    func test_launchReconciliation_happyPath_ordersGateLoadLiveStateApply() async {
        let log = CallLog()   // captured (not self) — Swift-6 Sendable-safe closures

        await DownloadReconciliation.runLaunchReconciliation(
            isRegistryLoaded: {
                log.record("isRegistryLoaded")
                return true
            },
            loadPersisted: {
                log.record("loadPersisted")
                return [Self.record("A", task: 7)]
            },
            liveTaskIdentifiers: {
                log.record("liveTaskIdentifiers")
                return []                      // task 7 is dead → restart
            },
            registryState: { bookID in
                log.record("registryState", args: ["bookId": bookID])
                return .downloadNeeded
            },
            apply: { decision in
                log.record("apply", args: ["decision": "\(decision)"])
            }
        )

        XCTAssertEqual(
            log.snapshot().map(\.method),
            ["isRegistryLoaded", "loadPersisted", "liveTaskIdentifiers", "registryState", "apply"],
            "Launch reconciliation order: registry-loaded gate → load persisted → query live tasks → registry state → apply."
        )
    }

    /// INV-4 gate: the registry-loaded check is FIRST and blocking. When the
    /// registry has not loaded, reconciliation performs NO further work — it
    /// must not load persisted records, must not query live tasks, must not
    /// apply. A mutant that inverted the guard (or moved it after the load)
    /// would reconcile against an empty/half-loaded registry and mass-`.restart`
    /// or `.cleanup` real downloads.
    func test_launchReconciliation_registryNotLoaded_skipsAllWork() async {
        let log = CallLog()
        var liveQueried = false
        var applied = false

        await DownloadReconciliation.runLaunchReconciliation(
            isRegistryLoaded: {
                log.record("isRegistryLoaded")
                return false
            },
            loadPersisted: { log.record("loadPersisted"); return [Self.record("A", task: 7)] },
            liveTaskIdentifiers: { liveQueried = true; return [] },
            registryState: { _ in .downloadNeeded },
            apply: { _ in applied = true }
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["isRegistryLoaded"],
                       "gate must short-circuit before loadPersisted")
        XCTAssertFalse(liveQueried, "live-task query must not run when registry unloaded")
        XCTAssertFalse(applied, "no decision may be applied when registry unloaded")
    }

    /// Empty-persisted short-circuit: with zero durable records there is
    /// nothing to reconcile, so the (async) live-task query — the expensive
    /// step — must be skipped. Kills the `guard !persisted.isEmpty` mutant,
    /// which would otherwise `session.getAllTasks` on every clean launch.
    func test_launchReconciliation_noPersistedRecords_skipsLiveTaskQuery() async {
        let log = CallLog()
        var liveQueried = false

        await DownloadReconciliation.runLaunchReconciliation(
            isRegistryLoaded: { log.record("isRegistryLoaded"); return true },
            loadPersisted: { log.record("loadPersisted"); return [] },
            liveTaskIdentifiers: { liveQueried = true; log.record("liveTaskIdentifiers"); return [] },
            registryState: { _ in .downloadNeeded },
            apply: { _ in log.record("apply") }
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["isRegistryLoaded", "loadPersisted"],
                       "empty persisted set must short-circuit before the live-task query")
        XCTAssertFalse(liveQueried)
    }

    // MARK: - Helpers

    private static func record(_ bookID: String, task: Int) -> PersistedDownloadRecord {
        PersistedDownloadRecord(
            bookID: bookID,
            taskIdentifier: task,
            downloadURL: URL(string: "https://example.invalid/\(bookID)")!,
            account: "acct-1",
            expectedBytes: nil,
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
