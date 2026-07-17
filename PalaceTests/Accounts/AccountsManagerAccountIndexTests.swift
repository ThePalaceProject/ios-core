//
//  AccountsManagerAccountIndexTests.swift
//  PalaceTests
//
//  Guards the O(1) `uuid → Account` index behind `AccountsManager.account(_:)`
//  (hermeticity-leaker-accountdetail-vm). The prior implementation linear-scanned
//  every bucket of `accountSets` on the MAIN thread for every account-change view
//  refresh; over the ~1142-account registry snapshot that saturated the main
//  thread (the post-3.2.0 CI hang class) and cost the live app on every library
//  switch. These tests pin both the correctness of the index AND that it can
//  never desync from `accountSets` — the desync test is the structural guard:
//  remove the `accountByUUID = buildAccountIndex(...)` rebuild inside
//  `mutateAccountSets` and the reseed test fails (stale lookup survives).
//
//  Subclasses PalaceWiringTestCase for `makeFreshAccountsManager()` (pins the
//  defer flag + cancels background work on teardown) and the quiescence floor.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountsManagerAccountIndexTests: PalaceWiringTestCase {

    private func stubAccount(_ uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Stub \(uuid.prefix(6))")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: ImageCache.shared)
    }

    // MARK: - Correctness across buckets

    /// `account(_:)` must resolve a UUID that lives in ANY bucket, not only the
    /// first-enumerated one. Kills a mutation that indexes a single bucket.
    func testAccount_resolvesUUIDInEitherBucket() {
        let manager = makeFreshAccountsManager()
        let prodA = stubAccount("uuid-prod-A")
        let betaB = stubAccount("uuid-beta-B")
        manager._testSetAccountSet([prodA], forKey: "prod-hash")
        manager._testSetAccountSet([betaB], forKey: "beta-hash")

        XCTAssertEqual(manager.account("uuid-prod-A")?.uuid, "uuid-prod-A",
                       "account(_:) must resolve a UUID from the prod bucket")
        XCTAssertEqual(manager.account("uuid-beta-B")?.uuid, "uuid-beta-B",
                       "account(_:) must resolve a UUID from the beta bucket")
    }

    // MARK: - Desync guard (THE structural guard)

    /// Re-seeding a bucket must rebuild the index: an account removed by the
    /// reseed must STOP being found, and a newly-added one must START being
    /// found. If `mutateAccountSets` ever stops rebuilding `accountByUUID`, the
    /// removed account keeps resolving from the stale index → this fails.
    func testAccount_reseedRebuildsIndex_removedGoneAddedFound() {
        let manager = makeFreshAccountsManager()
        let a = stubAccount("uuid-A")
        let b = stubAccount("uuid-B")
        manager._testSetAccountSet([a, b], forKey: "hash")
        XCTAssertNotNil(manager.account("uuid-A"), "Precondition: A present after first seed")

        // Reseed the SAME bucket without A, with a new C.
        let c = stubAccount("uuid-C")
        manager._testSetAccountSet([b, c], forKey: "hash")

        XCTAssertNil(manager.account("uuid-A"),
                     "A was removed by the reseed — a stale index would still return it")
        XCTAssertEqual(manager.account("uuid-C")?.uuid, "uuid-C",
                       "C was added by the reseed and must be found")
        XCTAssertNotNil(manager.account("uuid-B"), "B survived the reseed")
    }

    // MARK: - Boundary cases (preserve prior contract)

    func testAccount_unknownUUID_returnsNil() {
        let manager = makeFreshAccountsManager()
        manager._testSetAccountSet([stubAccount("uuid-X")], forKey: "hash")
        XCTAssertNil(manager.account("uuid-does-not-exist"))
        XCTAssertNil(manager.account(""), "Empty UUID must not resolve")
    }

    // MARK: - Pure index builder semantics

    /// `buildAccountIndex` maps every account by UUID; on a duplicate UUID across
    /// buckets the last-enumerated wins (documented equivalent of the prior
    /// nondeterministic "first across values"). Kills a mutation that drops
    /// accounts or mis-keys the index.
    func testBuildAccountIndex_mapsAllAccounts() {
        let a = stubAccount("u-1")
        let b = stubAccount("u-2")
        let index = AccountsManager.buildAccountIndex(["h1": [a], "h2": [b]])
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index["u-1"]?.uuid, "u-1")
        XCTAssertEqual(index["u-2"]?.uuid, "u-2")
        XCTAssertNil(index["missing"])
    }

    func testBuildAccountIndex_emptyInput_isEmpty() {
        XCTAssertTrue(AccountsManager.buildAccountIndex([:]).isEmpty)
    }

    /// Tie-break contract for a UUID present in MORE THAN ONE bucket (e.g. an
    /// account in both the prod and beta registries). The index maps the UUID to
    /// exactly one entry; WHICH bucket's Account instance wins is unspecified
    /// (dict-value iteration order) — the same nondeterminism the prior
    /// `accountSets.values.first { contains }` scan had. What IS pinned: the
    /// lookup resolves to a non-nil account carrying that exact UUID, never nil
    /// and never a phantom. This documents the one behavior the O(1) migration
    /// preserved-but-restated (qa follow-up on #1).
    func testBuildAccountIndex_duplicateUUIDAcrossBuckets_resolvesToThatUUID() {
        let dup = "urn:uuid:dup-across-buckets"
        let prodCopy = stubAccount(dup)
        let betaCopy = stubAccount(dup)
        let index = AccountsManager.buildAccountIndex(["prod": [prodCopy], "beta": [betaCopy]])

        XCTAssertEqual(index.count, 1, "a UUID in two buckets collapses to one index entry")
        XCTAssertEqual(index[dup]?.uuid, dup,
                       "the entry must carry the duplicated UUID (which instance is unspecified)")

        // Same contract through the live lookup.
        let manager = makeFreshAccountsManager()
        manager._testSetAccountSet([prodCopy], forKey: "prod")
        manager._testSetAccountSet([betaCopy], forKey: "beta")
        XCTAssertEqual(manager.account(dup)?.uuid, dup,
                       "account(_:) resolves a cross-bucket duplicate UUID to that UUID, never nil")
    }

    // MARK: - Complexity contract (THE recurrence guard for the hang fix)

    /// `account(_:)` MUST be ~constant-time, independent of the account count —
    /// that O(1) property is the actual hang fix (a churn-fired observer doing
    /// account() lookups over the ~1142-account snapshot saturated the main
    /// thread). A revert to the old `accountSets.values.first { contains(where:) }`
    /// O(n) scan must FAIL this test.
    ///
    /// Comparative, not absolute-timing (machine-independent, CI-safe): the same
    /// K lookups are timed against a SMALL bucket and a LARGE bucket. Per-call
    /// `performRead` dispatch overhead is identical for both, so for an O(1) index
    /// the two times are within a small constant factor; an O(n) scan makes the
    /// large-bucket time scale with N (≈ large/small ≈ 40×). The 8× ceiling sits
    /// well above O(1) noise and far below the O(n) blow-up.
    func testAccount_lookupIsConstantTime_notLinearInAccountCount() {
        let manager = makeFreshAccountsManager()
        let small = 50
        let large = 2000
        let lookups = 20_000

        func timeLookups(bucketSize: Int) -> TimeInterval {
            let accounts = (0..<bucketSize).map { stubAccount("scale-\(bucketSize)-\($0)") }
            manager._testSetAccountSet(accounts, forKey: "scale-\(bucketSize)")
            // Look up the LAST uuid — worst case for a linear scan (it would scan
            // the whole bucket every call), best case is identical for the index.
            let target = "scale-\(bucketSize)-\(bucketSize - 1)"
            // Warm up, then measure.
            for _ in 0..<1000 { _ = manager.account(target) }
            let start = Date()
            for _ in 0..<lookups { _ = manager.account(target) }
            return Date().timeIntervalSince(start)
        }

        let tSmall = timeLookups(bucketSize: small)
        let tLarge = timeLookups(bucketSize: large)

        XCTAssertEqual(manager.account("scale-\(large)-\(large - 1)")?.uuid,
                       "scale-\(large)-\(large - 1)",
                       "sanity: the large-bucket target resolves")
        XCTAssertLessThan(
            tLarge, tSmall * 8 + 0.05,
            "account(_:) must not scale with account count — \(large) accounts took "
            + "\(tLarge)s vs \(small) accounts \(tSmall)s for \(lookups) lookups. A "
            + "linear scan would be ~\(large / small)× slower; the O(1) index must "
            + "stay within a small constant factor. This is the hang-fix recurrence guard."
        )
    }
}
