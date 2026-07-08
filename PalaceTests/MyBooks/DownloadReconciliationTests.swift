//
//  DownloadReconciliationTests.swift
//  PalaceTests
//
//  Reliability WS-A — exhaustive unit coverage for the PURE launch
//  reconciliation decision matrix (seam S1). No URLSession, no I/O.
//  Guards INV-4: a still-running task is ADOPTED (never restarted / spuriously
//  failed); a dead task is restarted/failed/cleaned per the registry (source of
//  truth for the book's lifecycle).
//

import XCTest
@testable import Palace

final class DownloadReconciliationTests: XCTestCase {

    private func record(_ bookID: String, task: Int) -> PersistedDownloadRecord {
        PersistedDownloadRecord(
            bookID: bookID,
            taskIdentifier: task,
            downloadURL: URL(string: "https://example.org/\(bookID)")!,
            account: "acct-1",
            expectedBytes: 1_000,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func decide(
        _ rec: PersistedDownloadRecord,
        live: Set<Int>,
        state: TPPBookState?
    ) -> ReconcileDecision {
        var states: [String: TPPBookState] = [:]
        if let state { states[rec.bookID] = state }
        let decisions = DownloadReconciliation.reconcile(
            persisted: [rec],
            liveTaskIdentifiers: live,
            registryStates: states
        )
        XCTAssertEqual(decisions.count, 1, "one record -> one decision")
        return decisions[0]
    }

    // MARK: - Live task -> adopt (INV-4), regardless of registry state

    func testLiveTask_isAdopted_notRestarted_downloadingState() {
        let rec = record("b1", task: 7)
        let decision = decide(rec, live: [7], state: .downloading)
        XCTAssertEqual(decision, .adopt(bookID: "b1", taskIdentifier: 7))
    }

    func testLiveTask_isAdopted_evenIfRegistrySaysFailed() {
        // INV-4: the live task wins — a stale .downloadFailed registry record
        // must NOT override an actually-running task into a spurious failure.
        let rec = record("b2", task: 9)
        let decision = decide(rec, live: [9], state: .downloadFailed)
        XCTAssertEqual(decision, .adopt(bookID: "b2", taskIdentifier: 9))
    }

    func testLiveTask_isAdopted_evenWithNoRegistryEntry() {
        let rec = record("b3", task: 3)
        let decision = decide(rec, live: [3], state: nil)
        XCTAssertEqual(decision, .adopt(bookID: "b3", taskIdentifier: 3))
    }

    // MARK: - Dead task -> registry decides

    func testDeadTask_downloadSuccessful_isCleanedUp() {
        let decision = decide(record("b", task: 1), live: [], state: .downloadSuccessful)
        XCTAssertEqual(decision, .cleanup(bookID: "b"))
    }

    func testDeadTask_used_isCleanedUp() {
        let decision = decide(record("b", task: 1), live: [], state: .used)
        XCTAssertEqual(decision, .cleanup(bookID: "b"))
    }

    func testDeadTask_downloading_isRestarted() {
        let decision = decide(record("b", task: 1), live: [], state: .downloading)
        XCTAssertEqual(decision, .restart(bookID: "b"))
    }

    func testDeadTask_downloadNeeded_isRestarted() {
        let decision = decide(record("b", task: 1), live: [], state: .downloadNeeded)
        XCTAssertEqual(decision, .restart(bookID: "b"))
    }

    func testDeadTask_samlStarted_isRestarted() {
        let decision = decide(record("b", task: 1), live: [], state: .SAMLStarted)
        XCTAssertEqual(decision, .restart(bookID: "b"))
    }

    func testDeadTask_downloadFailed_isMarkedFailed() {
        let decision = decide(record("b", task: 1), live: [], state: .downloadFailed)
        XCTAssertEqual(decision, .markFailed(bookID: "b"))
    }

    func testDeadTask_unregistered_isCleanedUp() {
        let decision = decide(record("b", task: 1), live: [], state: .unregistered)
        XCTAssertEqual(decision, .cleanup(bookID: "b"))
    }

    func testDeadTask_holding_isCleanedUp() {
        let decision = decide(record("b", task: 1), live: [], state: .holding)
        XCTAssertEqual(decision, .cleanup(bookID: "b"))
    }

    func testDeadTask_returning_isCleanedUp() {
        let decision = decide(record("b", task: 1), live: [], state: .returning)
        XCTAssertEqual(decision, .cleanup(bookID: "b"))
    }

    func testDeadTask_unsupported_isCleanedUp() {
        let decision = decide(record("b", task: 1), live: [], state: .unsupported)
        XCTAssertEqual(decision, .cleanup(bookID: "b"))
    }

    func testDeadTask_noRegistryEntry_isCleanedUp() {
        let decision = decide(record("b", task: 1), live: [], state: nil)
        XCTAssertEqual(decision, .cleanup(bookID: "b"))
    }

    // MARK: - Aggregate / ordering

    func testEmptyPersisted_yieldsNoDecisions() {
        let decisions = DownloadReconciliation.reconcile(
            persisted: [],
            liveTaskIdentifiers: [1, 2, 3],
            registryStates: ["x": .downloading]
        )
        XCTAssertTrue(decisions.isEmpty)
    }

    func testMixedBatch_eachRecordDecidedIndependently_orderPreserved() {
        let live = record("live", task: 10)     // adopt
        let dead = record("dead", task: 20)      // restart (.downloading)
        let done = record("done", task: 30)      // cleanup (.downloadSuccessful)
        let gone = record("gone", task: 40)      // markFailed (.downloadFailed)

        let decisions = DownloadReconciliation.reconcile(
            persisted: [live, dead, done, gone],
            liveTaskIdentifiers: [10],
            registryStates: [
                "live": .downloading,
                "dead": .downloading,
                "done": .downloadSuccessful,
                "gone": .downloadFailed
            ]
        )

        XCTAssertEqual(decisions, [
            .adopt(bookID: "live", taskIdentifier: 10),
            .restart(bookID: "dead"),
            .cleanup(bookID: "done"),
            .markFailed(bookID: "gone")
        ])
    }

    func testTwoLiveRecords_bothAdopted_withOwnTaskIdentifiers() {
        let a = record("a", task: 100)
        let b = record("b", task: 200)
        let decisions = DownloadReconciliation.reconcile(
            persisted: [a, b],
            liveTaskIdentifiers: [100, 200],
            registryStates: ["a": .downloading, "b": .downloading]
        )
        XCTAssertEqual(decisions, [
            .adopt(bookID: "a", taskIdentifier: 100),
            .adopt(bookID: "b", taskIdentifier: 200)
        ])
    }
}
