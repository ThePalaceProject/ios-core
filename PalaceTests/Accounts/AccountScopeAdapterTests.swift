//
//  AccountScopeAdapterTests.swift
//  PalaceTests
//
//  Pins the app-side `AccountsManagerAccountScopeAdapter` — the boundary that
//  realizes the god-class-decomposition Wave 2b Book→Accounts inversion. The
//  PalaceBookRegistry engine consumes ONLY this value-only surface; these tests
//  lock the four members it forwards so a future AccountsManager refactor can't
//  silently break the registry's account scoping (brief §3.4).
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace
import PalaceBookRegistry
import PalaceCatalog
import PalaceBookModel

final class AccountScopeAdapterTests: PalaceWiringTestCase {
    // `cancellables` (and its teardown reset) are provided by PalaceWiringTestCase.

    private func makeAccount(uuid: String) -> Account {
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/catalog",
                              rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: uuid, title: "Fixture \(uuid)"),
            images: nil
        )
        return Account(publication: pub, imageCache: MockImageCache())
    }

    /// `currentAccountID` is nil before a library is selected, then mirrors the
    /// manager's `currentAccount.uuid` — the exact value the facade captures
    /// synchronously at every mutation dispatch (PP-4129).
    func testCurrentAccountID_nilBeforeSelection_thenMirrorsSeededAccount() {
        let manager = makeFreshAccountsManager()
        let adapter = AccountsManagerAccountScopeAdapter(accountsManager: manager)

        XCTAssertNil(adapter.currentAccountID, "no account selected yet → nil")

        let uuid = "adapter-A-\(UUID().uuidString)"
        _ = manager._seedAccountForTesting(makeAccount(uuid: uuid))

        XCTAssertEqual(adapter.currentAccountID, uuid,
                       "adapter must mirror the manager's current-account uuid")
    }

    /// The change publisher fires on `.TPPCurrentAccountDidChange` — the signal
    /// the registry's account-change observer (empty-store invalidation + reload)
    /// subscribes to.
    func testAccountDidChangePublisher_firesOnCurrentAccountDidChangeNotification() {
        let manager = makeFreshAccountsManager()
        let adapter = AccountsManagerAccountScopeAdapter(accountsManager: manager)

        var fired = false
        adapter.accountDidChangePublisher
            .sink { _ in fired = true }
            .store(in: &cancellables)

        // The adapter re-posts `.TPPCurrentAccountDidChange` through Combine's
        // NotificationCenter publisher with NO `.receive(on:)`, so the sink runs
        // SYNCHRONOUSLY during `post`. Drain the main queue to settle delivery,
        // then assert synchronously — no wall-clock deadline to starve under
        // parallel sim clones (STARVE-001).
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        drainMainQueue()

        XCTAssertTrue(fired,
                      "the adapter must forward .TPPCurrentAccountDidChange to accountDidChangePublisher")
    }

    /// An unknown account resolves to nil (account-not-found) rather than throwing —
    /// the registry treats nil as "anonymous / no loans" and reverts to `.loaded`,
    /// the documented safe-revert divergence from the pre-inversion captured-object path.
    func testLoansURL_unknownAccount_returnsNil() async {
        let manager = makeFreshAccountsManager()
        let adapter = AccountsManagerAccountScopeAdapter(accountsManager: manager)

        let url = try? await adapter.loansURL(
            forAccount: "does-not-exist-\(UUID().uuidString)",
            readinessTimeout: 30
        )

        XCTAssertNil(url ?? nil, "unknown account → nil loans URL (safe revert)")
    }

    /// THE #18414 PRODUCER TEST. An account wedged at `.detailsLoading` — the
    /// dropped-`authentication_document`-completion state — must make the adapter
    /// THROW `.readinessTimedOut` once the caller's bound elapses, never hang.
    ///
    /// Why this test exists at this layer: the 3.2.3 hotfix's timeout test
    /// (`BookRegistrySyncReadinessTests.testReadiness_wedgedAtDetailsLoading_bounded_…`)
    /// exercises `Account.awaitReady(timeout:)` — the HELPER — directly. When the
    /// Wave 3 S2 seam extraction moved the readiness await into this adapter and
    /// dropped `timeout:`, that helper test stayed green while the real production
    /// path went unbounded again: registry sync never completed and My Books spun
    /// forever (HelpSpot #18619, #18624). Only a test on the producer catches that.
    ///
    /// Kill case: revert the adapter to the unbounded `account.awaitReady()` and this
    /// test fails on XCTest's own timeout instead of the assertion — it cannot pass.
    func testLoansURL_accountWedgedAtDetailsLoading_throwsReadinessTimedOutWithinBound() async {
        let manager = makeFreshAccountsManager()
        let uuid = "adapter-wedged-\(UUID().uuidString)"
        let account = makeAccount(uuid: uuid)
        _ = manager._seedAccountForTesting(account)
        account._setState(.detailsLoading)   // wedged; no transition ever comes

        let adapter = AccountsManagerAccountScopeAdapter(accountsManager: manager)
        let bound: TimeInterval = 0.3
        let started = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await adapter.loansURL(forAccount: uuid, readinessTimeout: bound)
            XCTFail("A wedged account must not resolve — the adapter has to surface the timeout so the registry can revert to .loaded and retry")
        } catch let error as AccountLoadError {
            guard case .readinessTimedOut = error else {
                return XCTFail("Expected .readinessTimedOut so BookRegistrySync.sync's catch reverts to .loaded; got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError.readinessTimedOut, got \(type(of: error)): \(error)")
        }

        // The adapter must honor the CALLER's bound, not some longer internal one.
        // Generous ceiling (bound × 10) so a starved parallel sim clone can't flake
        // this; an unbounded await blows past any ceiling because it never returns.
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, bound * 10,
                          "the adapter must give up on the caller's timeout, not wait indefinitely (elapsed \(elapsed)s for a \(bound)s bound)")
    }

    /// A library with no stored credentials reports false — the gate that makes
    /// `BookRegistrySync.sync` skip the loans fetch (avoiding a guaranteed 401)
    /// during the unhydrated window (F-007 / PP-4164).
    func testHasCredentials_libraryWithNoStoredCredentials_isFalse() {
        let manager = makeFreshAccountsManager()
        let adapter = AccountsManagerAccountScopeAdapter(accountsManager: manager)

        XCTAssertFalse(adapter.hasCredentials(forAccount: "no-creds-\(UUID().uuidString)"),
                       "a library with no stored credentials must report false")
    }
}
