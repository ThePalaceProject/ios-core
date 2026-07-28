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

        let url = try? await adapter.loansURL(forAccount: "does-not-exist-\(UUID().uuidString)")

        XCTAssertNil(url ?? nil, "unknown account → nil loans URL (safe revert)")
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
