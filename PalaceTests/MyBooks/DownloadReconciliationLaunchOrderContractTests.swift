//
//  DownloadReconciliationLaunchOrderContractTests.swift
//  PalaceTests
//
//  Reliability WS-A — contract-snapshot of the launch reconciliation call
//  ORDER (INV-4): registry-loaded gate FIRST, then load persisted records, then
//  snapshot live URLSession tasks (getAllTasks), then read per-book registry
//  state, then apply each decision. A refactor that reads live tasks before the
//  registry-loaded gate, or applies before reconciling, drifts this snapshot.
//

import XCTest
@testable import Palace

@MainActor
final class DownloadReconciliationLaunchOrderContractTests: XCTestCase {

    private func record(_ bookID: String, task: Int) -> PersistedDownloadRecord {
        PersistedDownloadRecord(
            bookID: bookID, taskIdentifier: task,
            downloadURL: URL(string: "https://example.org/\(bookID)")!,
            account: "acct", expectedBytes: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLaunchReconciliation_callOrder_registryLoad_getAllTasks_reconcile_apply() async {
        let log = CallLog()
        // @Sendable closures: runLaunchReconciliation is nonisolated async, so
        // non-Sendable closures from this @MainActor test are a Swift 6
        // sending error. CallLog is @unchecked Sendable; the record is
        // precomputed (Sendable struct) so no capture of MainActor self.
        let persisted = [record("b", task: 5)]

        await DownloadReconciliation.runLaunchReconciliation(
            isRegistryLoaded: { @Sendable in
                log.record("isRegistryLoaded")
                return true
            },
            loadPersisted: { @Sendable in
                log.record("loadPersisted")
                return persisted
            },
            liveTaskIdentifiers: { @Sendable in
                log.record("getAllTasks")
                return []   // dead task -> restart (registry says .downloading)
            },
            registryState: { @Sendable bookID in
                log.record("registryState", args: ["bookID": bookID])
                return .downloading
            },
            apply: { @Sendable decision in
                log.record("apply", args: ["decision": decision])
            }
        )

        ContractSnapshot.assert(log, named: "launchReconciliationOrder")
    }

    func testLaunchReconciliation_registryNotLoaded_gatesBeforeAnyTaskOrPersistenceRead() async {
        // INV-4 ordering guard: if the registry has not loaded, reconciliation
        // must not read persisted records or query live tasks.
        let log = CallLog()

        // @Sendable: same sending-boundary rationale as the test above.
        await DownloadReconciliation.runLaunchReconciliation(
            isRegistryLoaded: { @Sendable in
                log.record("isRegistryLoaded")
                return false
            },
            loadPersisted: { @Sendable in
                log.record("loadPersisted")
                return []
            },
            liveTaskIdentifiers: { @Sendable in
                log.record("getAllTasks")
                return []
            },
            registryState: { @Sendable _ in .unregistered },
            apply: { @Sendable _ in log.record("apply") }
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["isRegistryLoaded"],
                       "not-loaded gate must short-circuit before persistence / task reads")
    }
}
