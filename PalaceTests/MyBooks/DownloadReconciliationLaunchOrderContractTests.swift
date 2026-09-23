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

    // Pure factory — no instance state. `static` so the closures passed to the
    // async `runLaunchReconciliation` don't capture `self` (which, under Swift 6,
    // would make the non-`@Sendable` closure params send this @MainActor test
    // across the actor boundary). Called as `Self.record(...)`.
    private nonisolated static func record(_ bookID: String, task: Int) -> PersistedDownloadRecord {
        PersistedDownloadRecord(
            bookID: bookID, taskIdentifier: task,
            downloadURL: URL(string: "https://example.org/\(bookID)")!,
            account: "acct", expectedBytes: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLaunchReconciliation_callOrder_registryLoad_getAllTasks_reconcile_apply() async {
        let log = CallLog()

        await DownloadReconciliation.runLaunchReconciliation(
            isRegistryLoaded: { @Sendable in
                log.record("isRegistryLoaded")
                return true
            },
            loadPersisted: { @Sendable in
                log.record("loadPersisted")
                return [Self.record("b", task: 5)]
            },
            liveTasks: { @Sendable in
                log.record("getAllTasks")
                return [:]   // dead task -> restart (registry says .downloading)
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

        await DownloadReconciliation.runLaunchReconciliation(
            isRegistryLoaded: { @Sendable in
                log.record("isRegistryLoaded")
                return false
            },
            loadPersisted: { @Sendable in
                log.record("loadPersisted")
                return []
            },
            liveTasks: { @Sendable in
                log.record("getAllTasks")
                return [:]
            },
            registryState: { @Sendable _ in .unregistered },
            apply: { @Sendable _ in log.record("apply") }
        )

        XCTAssertEqual(log.snapshot().map(\.method), ["isRegistryLoaded"],
                       "not-loaded gate must short-circuit before persistence / task reads")
    }
}
