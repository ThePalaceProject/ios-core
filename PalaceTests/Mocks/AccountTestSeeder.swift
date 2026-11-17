//
//  Installs a fixture Account via `AccountsManager._seedAccountForTesting(_:)`
//  (DEBUG only) so production-stack tests can run without a signed-in account;
//  previously they hit `XCTSkip` when `currentAccount` was nil. Call
//  `seedAccountIfNeeded(on:)` in the test body and `defer { cleanup() }` so the
//  production singleton is left clean.
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
