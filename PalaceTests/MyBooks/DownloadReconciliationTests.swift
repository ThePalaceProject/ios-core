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
import PalaceBookModel

@MainActor
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

    /// `live` is the set of task identifiers that are still running AND belong to
    /// this record (same download URL) — the ordinary case. PP-4997 is about the
    /// case these two things come apart, which `decideColliding` below drives.
    private func decide(
        _ rec: PersistedDownloadRecord,
        live: Set<Int>,
        state: TPPBookState?
    ) -> ReconcileDecision {
        decide(rec, liveTasks: Dictionary(uniqueKeysWithValues: live.map { ($0, rec.downloadURL) }),
               state: state)
    }

    private func decide(
        _ rec: PersistedDownloadRecord,
        liveTasks: [Int: URL],
        state: TPPBookState?
    ) -> ReconcileDecision {
        var states: [String: TPPBookState] = [:]
        if let state { states[rec.bookID] = state }
        let decisions = DownloadReconciliation.reconcile(
            persisted: [rec],
            liveTasks: liveTasks,
            registryStates: states
        )
        XCTAssertEqual(decisions.count, 1, "one record -> one decision")
        return decisions[0]
    }

    // MARK: - Live task -> adopt (INV-4), regardless of registry state

    // MARK: - PP-4997: a task identifier alone does not identify a download

    /// Task identifiers are only unique within ONE run of the app — a relaunch
    /// starts numbering again from 1. So a leftover record for task 1 can collide
    /// with a DIFFERENT book's live task 1. Adopting on the identifier alone
    /// routes that download's progress and its finished file to the wrong title,
    /// silently: no error, no alert, no log line. The record already carries the
    /// download URL, which distinguishes them.
    /// Collides on identifier, different book. Asserted as the EXACT decision
    /// rather than "not adopt" — an earlier version used XCTAssertNotEqual, which
    /// passes for any non-adopt outcome including a wrong one, and the QA review
    /// showed it died on exactly the same mutants as this one. One test, stronger
    /// assertion.
    func testCollidingTaskIdentifier_differentURL_restartsWhenStillWanted() {
        let rec = record("book-A", task: 1)
        let decision = decide(rec, liveTasks: [1: URL(string: "https://example.org/book-B")!],
                              state: .downloading)
        XCTAssertEqual(decision, .restart(bookID: "book-A"))
    }

    /// THE COMMON CASE, and the one the first version of this fix got wrong.
    /// If a relaunch renumbers tasks — which is the very mechanism PP-4997 rests
    /// on — then the record's OWN restored download comes back under a different
    /// identifier. Requiring identifier AND url would refuse to adopt it and fall
    /// to `.restart`.
    ///
    /// That is NOT the unqualified double-start an earlier version of this
    /// comment claimed. `startDownload` returns early on `.downloading`
    /// (DownloadStartCoordinator), which is the state a book killed mid-download
    /// is in, so the restart is a no-op there. The real cost is quieter: the
    /// live task's callbacks are dropped because nothing maps its identifier to
    /// a book, the book sits in `.downloading` with no task, and registry sync
    /// later heals it to `.downloadFailed`. A download that was running fine
    /// becomes a failure the patron has to retry.
    ///
    /// Matching on url and adopting the LIVE identifier is correct whether or not
    /// identifiers survive a relaunch, which is why it is the shape used.
    func testSameURL_renumberedTaskIdentifier_isAdoptedWithTheLiveIdentifier() {
        let rec = record("book-A", task: 1)          // persisted before the kill
        let live = [9: rec.downloadURL]              // same download, renumbered

        let decision = decide(rec, liveTasks: live, state: .downloading)

        XCTAssertEqual(decision, .adopt(bookID: "book-A", taskIdentifier: 9),
                       "refused to adopt the record's own renumbered task, which "
                       + "restarts a download that is still running")
    }

    /// Two live tasks fetching the same url: we cannot tell which belongs to this
    /// record, so adopt neither. Declining is safe (the registry restarts it);
    /// guessing would re-introduce PP-4997 by another route.
    /// The actual relaunch cell, which existed only as the union of two separate
    /// tests: the record's identifier has been REUSED by a different book's task
    /// while the record's own download is live under a new number. Adoption must
    /// follow the URL to task 9, never the stale identifier 1.
    func testRelaunch_identifierReusedByAnotherDownload_adoptsByURL() {
        let rec = record("book-A", task: 1)
        let other = URL(string: "https://example.org/book-B")!
        let live = [1: other, 9: rec.downloadURL]

        let decision = decide(rec, liveTasks: live, state: .downloading)

        XCTAssertEqual(decision, .adopt(bookID: "book-A", taskIdentifier: 9),
                       "adopted the stale identifier's task — that is the wrong "
                       + "book's download, which is PP-4997 itself")
    }

    // MARK: - PP-4997: two BOOKS sharing one download URL

    /// The URL discriminator rests on "one download URL identifies one book".
    /// Two catalogs can legitimately surface the same open-access title, and
    /// then the URL tells the two records apart no better than the identifier
    /// did. Neither may be adopted: `taskIdentifierToBook` is last-write-wins,
    /// so adopting both would hand the finished file to whichever book was
    /// applied last — PP-4997's own symptom, re-entered through its fix.
    func testTwoBooksSharingOneDownloadURL_neitherIsAdopted() {
        let shared = URL(string: "https://example.org/shared-open-access")!
        let recA = PersistedDownloadRecord(
            bookID: "book-A", taskIdentifier: 1, downloadURL: shared,
            account: "acct-1", expectedBytes: 1_000,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let recB = PersistedDownloadRecord(
            bookID: "book-B", taskIdentifier: 2, downloadURL: shared,
            account: "acct-1", expectedBytes: 1_000,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let decisions = DownloadReconciliation.reconcile(
            persisted: [recA, recB],
            liveTasks: [1: shared],
            registryStates: ["book-A": .downloading, "book-B": .downloading]
        )

        XCTAssertEqual(decisions, [.restart(bookID: "book-A"), .restart(bookID: "book-B")],
                       "a contested download URL was adopted; the finished file "
                       + "would go to whichever book applied last")
    }

    /// THE CONTESTED ARM ACROSS REGISTRY STATES.
    ///
    /// Declining adoption sends a record to `.restart` while a live task is
    /// still fetching that URL — the only arm in this function that does so.
    /// From `.downloading` that is inert (`startDownload` returns early), but
    /// from `.downloadNeeded` / `.SAMLStarted` it starts a SECOND task.
    ///
    /// That is deliberate and is the lesser harm: the alternative is adopting an
    /// ambiguous task, and `taskIdentifierToBook` is last-write-wins, so the
    /// finished file would be delivered to the wrong book. A duplicated download
    /// costs bandwidth; a misrouted one hands the patron a title they did not
    /// borrow. This table pins the choice so a later refactor cannot quietly
    /// reverse it.
    func testContestedURL_decisionIsRestart_inEveryWantsContentState() {
        let shared = URL(string: "https://example.org/shared-open-access")!
        func rec(_ id: String, _ task: Int) -> PersistedDownloadRecord {
            PersistedDownloadRecord(
                bookID: id, taskIdentifier: task, downloadURL: shared,
                account: "acct-1", expectedBytes: 1_000,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }

        for state in [TPPBookState.downloading, .downloadNeeded, .SAMLStarted] {
            let decisions = DownloadReconciliation.reconcile(
                persisted: [rec("book-A", 1), rec("book-B", 2)],
                liveTasks: [1: shared],
                registryStates: ["book-A": state, "book-B": state]
            )
            XCTAssertEqual(decisions, [.restart(bookID: "book-A"), .restart(bookID: "book-B")],
                           "contested url under \(state) did not decline adoption")
        }
    }

    /// A contested url whose books are already DONE must not be restarted at all
    /// — the guard declines adoption, and the registry must still get the last
    /// word. Without this cell the guard could plausibly route a finished book
    /// back into a download.
    func testContestedURL_completedBooks_areCleanedUpNotRestarted() {
        let shared = URL(string: "https://example.org/shared-open-access")!
        func rec(_ id: String, _ task: Int) -> PersistedDownloadRecord {
            PersistedDownloadRecord(
                bookID: id, taskIdentifier: task, downloadURL: shared,
                account: "acct-1", expectedBytes: 1_000,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }

        let decisions = DownloadReconciliation.reconcile(
            persisted: [rec("book-A", 1), rec("book-B", 2)],
            liveTasks: [1: shared],
            registryStates: ["book-A": .downloadSuccessful, "book-B": .used]
        )

        XCTAssertEqual(decisions, [.cleanup(bookID: "book-A"), .cleanup(bookID: "book-B")],
                       "a finished book was routed back into a download")
    }

    /// The guard is scoped to the CONTESTED url only — an unrelated record in
    /// the same pass still adopts normally.
    func testContestedURL_doesNotBlockAnUnrelatedRecordInTheSamePass() {
        let shared = URL(string: "https://example.org/shared-open-access")!
        let recA = PersistedDownloadRecord(
            bookID: "book-A", taskIdentifier: 1, downloadURL: shared,
            account: "acct-1", expectedBytes: 1_000,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let recB = PersistedDownloadRecord(
            bookID: "book-B", taskIdentifier: 2, downloadURL: shared,
            account: "acct-1", expectedBytes: 1_000,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let recC = record("book-C", task: 3)

        let decisions = DownloadReconciliation.reconcile(
            persisted: [recA, recB, recC],
            liveTasks: [1: shared, 3: recC.downloadURL],
            registryStates: ["book-A": .downloading, "book-B": .downloading,
                             "book-C": .downloading]
        )

        XCTAssertEqual(decisions.last, .adopt(bookID: "book-C", taskIdentifier: 3),
                       "the collision guard is over-broad — it blocked a record "
                       + "that shares no url with anything")
    }

    func testAmbiguousURL_twoLiveTasksSameURL_isNotAdopted() {
        let rec = record("book-A", task: 1)
        let live = [7: rec.downloadURL, 8: rec.downloadURL]

        let decision = decide(rec, liveTasks: live, state: .downloading)

        XCTAssertEqual(decision, .restart(bookID: "book-A"))
    }

    /// ...unless one of them is the record's own identifier, which disambiguates.
    func testAmbiguousURL_butExactIdentifierMatch_prefersTheExactTask() {
        let rec = record("book-A", task: 7)
        let live = [7: rec.downloadURL, 8: rec.downloadURL]

        let decision = decide(rec, liveTasks: live, state: .downloading)

        XCTAssertEqual(decision, .adopt(bookID: "book-A", taskIdentifier: 7))
    }

    /// Clean path: same identifier AND same URL is the genuine resume, and must
    /// still adopt. A guard only tested against the violation is untested against
    /// false positives — refusing every adoption would "fix" PP-4997 by breaking
    /// download resume entirely.
    func testMatchingTaskIdentifierAndURL_isStillAdopted() {
        let rec = record("book-A", task: 1)
        let decision = decide(rec, liveTasks: [1: rec.downloadURL], state: .downloading)
        XCTAssertEqual(decision, .adopt(bookID: "book-A", taskIdentifier: 1))
    }

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
            liveTasks: [1: URL(string: "https://example.org/x")!],
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
            liveTasks: [10: live.downloadURL],
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
            liveTasks: [100: a.downloadURL, 200: b.downloadURL],
            registryStates: ["a": .downloading, "b": .downloading]
        )
        XCTAssertEqual(decisions, [
            .adopt(bookID: "a", taskIdentifier: 100),
            .adopt(bookID: "b", taskIdentifier: 200)
        ])
    }
}
