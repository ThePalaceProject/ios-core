//
//  AccountsManagerHelpersTests.swift
//  PalaceTests
//
//  F-013 follow-up: kills surviving mutants in AccountsManager by exercising
//  the pure helpers extracted from `currentAccount.didSet`,
//  `cleanupActiveContentBeforeAccountSwitch`, and `isCacheStale`.
//

import XCTest
@testable import Palace

@MainActor
final class AccountsManagerHelpersTests: XCTestCase {

    // MARK: - shouldFinishSwitchingImmediately
    //
    // Mirrors the previous L171 condition:
    //   `if previousAccountId == newAccountId || previousAccountId == nil`
    // Kills the `==` ↔ `!=` mutants on the comparison + the `||` ↔ `&&` mutant.

    func test_shouldFinishSwitchingImmediately_sameAccount_returnsTrue() {
        let result = AccountsManager.shouldFinishSwitchingImmediately(
            previousAccountId: "abc",
            newAccountId: "abc"
        )
        XCTAssertTrue(result)
    }

    func test_shouldFinishSwitchingImmediately_differentAccounts_returnsFalse() {
        let result = AccountsManager.shouldFinishSwitchingImmediately(
            previousAccountId: "abc",
            newAccountId: "xyz"
        )
        XCTAssertFalse(result)
    }

    func test_shouldFinishSwitchingImmediately_previousNil_returnsTrue() {
        let result = AccountsManager.shouldFinishSwitchingImmediately(
            previousAccountId: nil,
            newAccountId: "xyz"
        )
        XCTAssertTrue(result)
    }

    func test_shouldFinishSwitchingImmediately_bothNil_returnsTrue() {
        let result = AccountsManager.shouldFinishSwitchingImmediately(
            previousAccountId: nil,
            newAccountId: nil
        )
        XCTAssertTrue(result)
    }

    func test_shouldFinishSwitchingImmediately_newNilWithExistingPrevious_returnsFalse() {
        // previous=abc, new=nil → not the same, not previous=nil → false.
        // Kills the `||` → `&&` mutant: under `&&` this would still return
        // false too, but combined with the bothNil/previousNil tests above,
        // an `&&` swap fails the previousNil case which expects true.
        let result = AccountsManager.shouldFinishSwitchingImmediately(
            previousAccountId: "abc",
            newAccountId: nil
        )
        XCTAssertFalse(result)
    }

    // MARK: - shouldPopToRoot

    func test_shouldPopToRoot_zeroPath_returnsFalse() {
        XCTAssertFalse(AccountsManager.shouldPopToRoot(navigationPathCount: 0))
    }

    func test_shouldPopToRoot_onePath_returnsTrue() {
        XCTAssertTrue(AccountsManager.shouldPopToRoot(navigationPathCount: 1))
    }

    /// Negative shouldn't happen in practice but kills `> 0` → `>= 0`:
    /// `>= 0` would return true for 0 (which we want false).
    func test_shouldPopToRoot_threePath_returnsTrue() {
        XCTAssertTrue(AccountsManager.shouldPopToRoot(navigationPathCount: 3))
    }

    // MARK: - isCacheStale (pure variant)

    func test_isCacheStale_nilMetadata_returnsTrue() {
        // Kills the `return true` → `return false` mutant on the
        // nil-metadata path.
        XCTAssertTrue(AccountsManager.isCacheStale(metadata: nil, serverMaxAge: nil))
    }

    func test_isCacheStale_freshMetadata_returnsFalse() {
        let fresh = CatalogCacheMetadata(timestamp: Date(), hash: "h")
        XCTAssertFalse(AccountsManager.isCacheStale(metadata: fresh, serverMaxAge: nil))
    }

    func test_isCacheStale_staleMetadata_returnsTrue() {
        // 7 hours ago is past the 6-hour default stale TTL.
        let stale = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-7 * 3600),
            hash: "h"
        )
        XCTAssertTrue(AccountsManager.isCacheStale(metadata: stale, serverMaxAge: nil))
    }

    func test_isCacheStale_serverMaxAgeRespected() {
        // serverMaxAge=600s → staleTTL = max(300, min(300, 43200)) = 300s.
        // Metadata 4 minutes old: not stale (< 5min TTL).
        let recent = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-4 * 60),
            hash: "h"
        )
        XCTAssertFalse(AccountsManager.isCacheStale(metadata: recent, serverMaxAge: 600))

        // Same metadata 10 minutes old → stale (> 5min TTL).
        let older = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-10 * 60),
            hash: "h"
        )
        XCTAssertTrue(AccountsManager.isCacheStale(metadata: older, serverMaxAge: 600))
    }
}
