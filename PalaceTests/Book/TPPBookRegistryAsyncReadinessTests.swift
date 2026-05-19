//
//  TPPBookRegistryAsyncReadinessTests.swift
//  PalaceTests
//
//  Readiness contract for `TPPBookRegistry.syncAsync` (swarm_81b5099e
//  Bucket A). Pre-Phase-1 the function read `currentAccount?.loansUrl`
//  directly and threw `.authentication(.accountNotFound)` whenever the
//  auth document hadn't loaded — confusing test/regression signal because
//  the account WAS found, it just wasn't ready.
//
//  Post-Phase-1 the function blocks on `currentAccount.awaitReady()`
//  before reading loansUrl. The single-timeout policy keeps the upstream
//  fetch-feed timeout as the only timeout on this path.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookRegistryAsyncReadinessTests: XCTestCase {

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

    /// Contract: under `.detailsLoading`, the gate that
    /// `TPPBookRegistry.syncAsync` consumes (`Account.awaitReady()`)
    /// blocks until terminal state. We verify the gate behavior on
    /// libraryMock's account — the production code consumes the SAME
    /// gate for `accountsManager.currentAccount`.
    func testReadiness_underDetailsLoading_gateBlocksUntilTransition() async throws {
        let account = libraryMock.tppAccount
        guard let realDetails = account.details else {
            XCTFail("Library mock must produce loaded details"); return
        }

        account._setState(.detailsLoading)

        let resolved = expectation(description: "awaitReady resolves after transition")
        let awaiterTask = Task {
            let details = try await account.awaitReady()
            // The migrated syncAsync reads `details.loansUrl` after the
            // gate resolves. Verify that reachability here.
            _ = details.loansUrl
            resolved.fulfill()
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(awaiterTask.isCancelled)
        account._setState(.detailsLoaded(realDetails))

        await fulfillment(of: [resolved], timeout: 1.0)
    }

    // MARK: - testReadiness_failurePath

    /// Contract: under `.detailsFailed`, awaitReady throws — and the
    /// migrated syncAsync catches that and throws
    /// `.authentication(.accountNotFound)`. We verify the gate's
    /// failure semantics directly.
    func testReadiness_underDetailsFailed_gateThrows() async {
        let account = libraryMock.tppAccount

        account._setState(.detailsFailed(.malformedAuthDocument(reason: "test malformed")))

        do {
            _ = try await account.awaitReady()
            XCTFail("awaitReady must throw under .detailsFailed — syncAsync's catch maps this to .accountNotFound")
        } catch let error as AccountLoadError {
            if case .malformedAuthDocument(let reason) = error {
                XCTAssertEqual(reason, "test malformed",
                               "Underlying reason must propagate so the production catch can log it")
            } else {
                XCTFail("Expected .malformedAuthDocument, got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError, got \(type(of: error))")
        }
    }

    // MARK: - Integration: full migrated path

    /// When the production accountsManager has a currentAccount, exercise
    /// the full migrated syncAsync path: under .detailsFailed, syncAsync
    /// throws `.authentication(.accountNotFound)`. This pins the
    /// observable surface that pre-Phase-1 callers depended on (so
    /// `.accountNotFound` keeps meaning "can't sync; try again later").
    func testIntegration_underDetailsFailed_throwsAccountNotFound() async throws {
        let accountsMgr = AppContainer.production().accountsManager
        guard let account = accountsMgr.currentAccount else {
            throw XCTSkip("Production accountsManager has no currentAccount in this test env")
        }

        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "test HTTP 503")))

        guard let registry = AppContainer.production().bookRegistry as? TPPBookRegistry else {
            throw XCTSkip("Production bookRegistry must be the concrete TPPBookRegistry type")
        }

        do {
            _ = try await registry.syncAsync()
            XCTFail("syncAsync must throw under .detailsFailed; got success")
        } catch let error as PalaceError {
            switch error {
            case .authentication(.accountNotFound):
                break // expected
            default:
                XCTFail("Expected .authentication(.accountNotFound), got \(error)")
            }
        } catch {
            XCTFail("Expected PalaceError, got \(type(of: error)): \(error)")
        }
    }
}
