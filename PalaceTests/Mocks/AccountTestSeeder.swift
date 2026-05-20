//
//  AccountTestSeeder.swift
//  PalaceTests
//
//  Shared helper for Phase 2 follow-up — DI seam that lets production-stack
//  integration tests run when no real signed-in account is present in the
//  test env. Pairs with `AccountsManager._seedAccountForTesting(_:)` (DEBUG
//  only) to install a fixture Account into `accountSets[currentHash]` and
//  set `currentAccountIdentifierKey` for the duration of the test.
//
//  Why this exists:
//  Four swarm Phase 1 production-stack integration tests guarded their
//  body with `XCTSkip` when `AppContainer.production().accountsManager
//  .currentAccount == nil`:
//    - AudiobookOpenStateRaceTests
//    - TPPBookRegistryAsyncReadinessTests
//    - BookRegistrySyncReadinessTests
//    - CarPlayAuthHelperReadinessTests
//  In the unit-test env (no UserDefaults seeded by a prior signed-in app
//  run) the production AccountsManager has no `currentAccount`, so the
//  tests skipped. Gate-level coverage (direct state-machine drives) was
//  already in place, but the production-stack wrappers weren't exercised.
//
//  Pattern: each test calls `seedAccountIfNeeded(on:)` in its body, drives
//  the returned Account's state machine, runs the production-path
//  assertion, and `defer { cleanup() }` removes the fixture so the
//  production singleton stays uncontaminated across tests.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import XCTest
import PalaceCatalog
@testable import Palace

extension XCTestCase {

    /// Returns the production currentAccount if present (CI sims with a
    /// real signed-in account), otherwise seeds a minimal fixture Account
    /// into the production AccountsManager and returns it along with a
    /// cleanup closure.
    ///
    /// The fixture has a stable catalogUrl + no auth doc, so its initial
    /// state-machine value is whatever the wiring drives it to. Tests
    /// call `_setState(...)` on the returned Account to put it into the
    /// state shape they're asserting against.
    ///
    /// `defer { cleanup() }` MUST be called by the test to remove the
    /// fixture. The closure is a no-op when an existing currentAccount
    /// was used.
    func seedAccountIfNeeded(
        on accountsMgr: AccountsManager,
        fixtureId: String,
        catalogUrl: String = "https://example.com/catalog"
    ) -> (Account, () -> Void) {
        if let existing = accountsMgr.currentAccount {
            return (existing, {})
        }
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: catalogUrl, rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: fixtureId, title: "Test Fixture \(fixtureId)"),
            images: nil
        )
        let fixture = Account(publication: pub, imageCache: MockImageCache())
        let cleanup = accountsMgr._seedAccountForTesting(fixture)
        return (fixture, cleanup)
    }
}
