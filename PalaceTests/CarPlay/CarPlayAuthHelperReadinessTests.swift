//
//  CarPlayAuthHelperReadinessTests.swift
//  PalaceTests
//
//  Readiness contract for `CarPlayAuthHelper.isAuthenticated`
//  (swarm_81b5099e Bucket A). Pre-Phase-1 the helper returned `true` for
//  any account whose `details` was still nil during the cold-launch
//  window (`treating unloaded details as no-auth-required`), letting
//  CarPlay try to start playback against a library that DID require
//  auth — failing later with a bare 401 on the fulfillment URL.
//
//  Post-Phase-1 the helper is `async` and blocks on awaitReady. On
//  failure it returns `false` (treat as unauthenticated → CarPlay shows
//  its existing auth-required alert).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class CarPlayAuthHelperReadinessTests: XCTestCase {

    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        libraryMock = nil
        super.tearDown()
    }

    // MARK: - testReadiness_blocksUntilLoaded (gate-level)

    /// Contract: under `.detailsLoading`, the gate consumed by
    /// `CarPlayAuthHelper.isAuthenticated` blocks until terminal state.
    /// Once `.detailsLoaded`, the helper evaluates `defaultAuth.needsAuth`
    /// against the loaded details (consistent answer, not silent "true"
    /// for no-details).
    func testReadiness_underDetailsLoading_gateBlocksUntilTransition() async throws {
        let account = libraryMock.tppAccount
        guard let realDetails = account.details else {
            XCTFail("Library mock must produce loaded details"); return
        }

        account._setState(.detailsLoading)

        let resolved = expectation(description: "gate resolves after transition")
        let awaiterTask = Task {
            // CarPlayAuthHelper.isAuthenticated calls
            // `account.awaitReady()` internally; here we test the gate
            // directly because the helper takes accountsManager as
            // parameter and we'd need to construct one whose
            // currentAccount returns our mock — which requires seeding
            // accountSets, out of scope.
            let details = try await account.awaitReady()
            // After resolution, the helper evaluates `defaultAuth`.
            _ = details.defaultAuth
            resolved.fulfill()
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(awaiterTask.isCancelled)
        account._setState(.detailsLoaded(realDetails))

        await fulfillment(of: [resolved], timeout: 1.0)
    }

    // MARK: - testReadiness_failurePath

    /// Contract: under `.detailsFailed`, the gate throws — and the
    /// migrated `CarPlayAuthHelper.isAuthenticated` catches that and
    /// returns `false` (unauthenticated). Pre-Phase-1 it would have
    /// returned `true` because the .details branch had nil details and
    /// the helper fell through to the no-auth-required default.
    func testReadiness_underDetailsFailed_gateThrows() async {
        let account = libraryMock.tppAccount

        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "test HTTP 503")))

        do {
            _ = try await account.awaitReady()
            XCTFail("awaitReady must throw under .detailsFailed — CarPlayAuthHelper relies on this to return false")
        } catch let error as AccountLoadError {
            if case .authDocumentFetchFailed(let desc) = error {
                XCTAssertEqual(desc, "test HTTP 503")
            } else {
                XCTFail("Expected .authDocumentFetchFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError, got \(type(of: error))")
        }
    }

    // MARK: - Integration: full migrated path (when production accountsManager has currentAccount)

    func testIntegration_underDetailsFailed_returnsFalse() async throws {
        // Rationale: integration test pins behavior against the production
        // AccountsManager's seed graph. Fresh test manager from
        // makeTestAppContainer() causes a state-machine trap when seeded
        // account is set to .detailsFailed and CarPlayAuthHelper.isAuthenticated
        // reads downstream state. Tracked for follow-up.
        let accountsMgr = AppContainer.production().accountsManager // MIGRATED-DEFERRED: swarm_5b500284 — integration test pins production seed graph
        let (currentAccount, cleanup) = seedAccountIfNeeded(on: accountsMgr,
                                                            fixtureId: "test-carplay-auth-\(UUID().uuidString)")
        defer { cleanup() }

        currentAccount._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "test HTTP 503")))

        let result = await CarPlayAuthHelper.isAuthenticated(accountsManager: accountsMgr)
        XCTAssertFalse(result,
                       "Under .detailsFailed the helper must surface as unauthenticated; pre-Phase-1 it returned true via the no-details fallthrough")
    }
}
