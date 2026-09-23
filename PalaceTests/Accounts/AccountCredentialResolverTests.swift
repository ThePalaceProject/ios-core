//
//  AccountCredentialResolverTests.swift
//  PalaceTests
//
//  Pins the Wave 3 / 3a-5 `AccountCredentialResolver` seam: per-account credential
//  resolution extracted from AccountsManager behind the injected resolver. The
//  end-to-end isolation contract is the retained `TPPCredentialIsolationE2ETests`
//  (F-034 500-iteration chaos gate) + `TPPPerAccountIsolationTests`, which route
//  through the hub facade unchanged. This file pins the resolver directly with a spy
//  `currentAccountIdProvider` — most importantly the F-016 ride-out.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AccountCredentialResolverTests: XCTestCase {

    // MARK: - Per-account cache isolation (F-034 surface)

    /// Same UUID → identical cached instance; distinct UUIDs → distinct instances with
    /// distinct immutable `boundLibraryUUID` keys. Seam-level mirror of the per-account
    /// isolation guarantee.
    func testUserAccount_cacheStability_perUUID() {
        let resolver = AccountCredentialResolver(currentAccountIdProvider: { nil })
        let a1 = resolver.userAccount(for: "urn:uuid:lib-A")
        let a2 = resolver.userAccount(for: "urn:uuid:lib-A")
        let b = resolver.userAccount(for: "urn:uuid:lib-B")

        XCTAssertTrue(a1 === a2, "same UUID must return the identical cached instance")
        XCTAssertFalse(a1 === b, "distinct UUIDs must return distinct instances")
        XCTAssertEqual(a1.boundLibraryUUID, "urn:uuid:lib-A")
        XCTAssertEqual(b.boundLibraryUUID, "urn:uuid:lib-B")
        XCTAssertNotEqual(a1.boundLibraryUUID, b.boundLibraryUUID, "keys must not collide across libraries")
    }

    // MARK: - currentUserAccount ride-out (F-016)

    /// id-present resolution returns `userAccount(for: id)` and records it as last-known.
    func testCurrentUserAccount_idPresent_resolvesCurrentLibrary() {
        let idBox = IdBox("urn:uuid:lib-A")
        let resolver = AccountCredentialResolver(currentAccountIdProvider: { idBox.value })

        let resolved = resolver.currentUserAccount
        XCTAssertEqual(resolved.boundLibraryUUID, "urn:uuid:lib-A")
        XCTAssertTrue(resolved === resolver.userAccount(for: "urn:uuid:lib-A"),
                      "currentUserAccount must return the cached instance for the current id")
    }

    /// THE isolation-critical pin (F-016): during the account-switch window where
    /// `currentAccountId` is transiently nil, `currentUserAccount` returns the
    /// LAST-RESOLVED signed-in instance — NOT the fresh-install placeholder — so
    /// consumers don't observe `hasCredentials == false` on a signed-in account and
    /// fire a spurious login modal.
    ///
    /// Kill case: dropping the `lastKnownCurrentUserAccount` ride-out (returning the
    /// placeholder in the nil window) → this fails (returns the sentinel instance).
    func testCurrentUserAccount_ridesOutNilWindow_returnsLastKnownNotPlaceholder() {
        let idBox = IdBox("urn:uuid:lib-A")
        let resolver = AccountCredentialResolver(currentAccountIdProvider: { idBox.value })

        let signedIn = resolver.currentUserAccount   // id-present → records last-known
        idBox.value = nil                            // enter the transient switch window

        let duringWindow = resolver.currentUserAccount
        XCTAssertTrue(duringWindow === signedIn,
                      "the ride-out must return the last-resolved instance during the nil window")
        XCTAssertNotEqual(duringWindow.boundLibraryUUID, "__no_account_selected__",
                          "the ride-out must NOT return the fresh-install placeholder")
    }

    /// True fresh install (nil from the start, no prior resolution) → the placeholder,
    /// which is not a real library so `hasCredentials()` is deterministically false.
    func testCurrentUserAccount_freshInstall_returnsPlaceholderWithNoCredentials() {
        let resolver = AccountCredentialResolver(currentAccountIdProvider: { nil })

        let placeholder = resolver.currentUserAccount
        XCTAssertEqual(placeholder.boundLibraryUUID, "__no_account_selected__",
                       "fresh install with no last-known returns the sentinel placeholder")
        XCTAssertFalse(placeholder.hasCredentials(),
                       "the placeholder must have no credentials")
    }

    // MARK: - Concurrency (the single-lock-span cache)

    /// Concurrent `userAccount(for:)` on one UUID yields exactly ONE cached instance,
    /// no crash — exercises the single `userAccountsLock` critical section that closes
    /// the F-034 TOCTOU.
    func testUserAccount_concurrentSameUUID_singleInstance() {
        let resolver = AccountCredentialResolver(currentAccountIdProvider: { nil })
        let sink = InstanceSink()

        DispatchQueue.concurrentPerform(iterations: 300) { _ in
            sink.record(resolver.userAccount(for: "urn:uuid:lib-A"))
        }
        XCTAssertEqual(sink.distinctCount, 1,
                       "check-build-insert under one lock span must yield a single cached instance per UUID")
    }
}

// MARK: - Test doubles

/// Mutable current-id source for the spy provider. `@unchecked Sendable`: mutated only
/// on the test thread before/after (not during) each `currentUserAccount` read.
fileprivate final class IdBox: @unchecked Sendable {
    var value: String?
    init(_ value: String?) { self.value = value }
}

/// Records distinct object identities seen across concurrent `userAccount(for:)` calls.
fileprivate final class InstanceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<ObjectIdentifier>()
    func record(_ account: TPPUserAccount) {
        lock.lock(); defer { lock.unlock() }
        seen.insert(ObjectIdentifier(account))
    }
    var distinctCount: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
}
