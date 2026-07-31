//
//  AccountRegistryStoreSeamTests.swift
//  PalaceTests
//
//  Pins the Wave 3 / 3a-2 `AccountRegistryStore` seam: the account-registry state and
//  its concurrency now live in an injected store, and `AccountsManager`'s retrieval
//  facades delegate to it.
//
//  Two lenses:
//   1. Concurrency (real store) — the index-coherence-under-barrier invariant, no
//      torn reads, and slim-fallback isolation. These are the guarantees the
//      extraction MUST preserve; each kills a specific locking-model mutant.
//   2. Routing (hub delegation) — inject a store, drive state through it, assert the
//      hub `account(_:)` / `accounts()` / `accountsHaveLoaded` facades reflect it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class AccountRegistryStoreSeamTests: PalaceWiringTestCase {

    // MARK: - Concurrency (real store)

    /// Contract: `accountByUUID` is rebuilt inside the SAME barrier as `accountSets`,
    /// so a concurrent reader never observes a stale index.
    ///
    /// Kill case: rebuild the index in a SEPARATE barrier (or async) after the mutate
    /// → a sampler lands in the window with updated sets + stale index → `_coherentSnapshot`
    /// returns false.
    func testMutate_indexStaysCoherentUnderConcurrentChurn() {
        let store = AccountRegistryStore(currentHash: "h")
        // Pre-build accounts on the MAIN thread. `Account.init` touches UIKit
        // (`UIImage(named:)`) + the image cache; creating them inside the concurrent
        // barrier while the test blocks the main thread risks a main-affine hang. The
        // concurrent section below only inserts pre-made (`Sendable`) accounts.
        let pool = (0..<8).map { Self.makeAccount("uuid-\($0)") }
        let incoherent = CoherenceBox(), lock = NSLock()

        // Bounded fan-out via `concurrentPerform` (self-joining, thread-pool-bounded)
        // rather than an unbounded `global().async` + `group.wait()` storm — the latter
        // starves under CI parallel-clone load (see deflake-parallel-clone-starvation).
        DispatchQueue.concurrentPerform(iterations: 300) { i in
            if i % 2 == 0 {
                store.mutate { $0["h"] = [pool[i % pool.count]] }
            } else if !store._coherentSnapshot() {
                lock.lock(); incoherent.flag = true; lock.unlock()
            }
        }
        // Sync read: FIFO-ordered after every enqueued barrier, so it also drains them.
        XCTAssertTrue(store._coherentSnapshot(), "index must be coherent once churn settles")
        XCTAssertFalse(incoherent.flag, "accountByUUID must never desync from accountSets under concurrent mutate")
    }

    /// Contract: `account(_:)` under concurrent reseeds never returns a phantom (an
    /// Account whose uuid differs from the one requested) and never crashes.
    ///
    /// Kill case: read `accountByUUID` outside `performRead` (unsynchronized) → torn
    /// read / phantom / crash under churn.
    func testAccount_concurrentMutate_neverReturnsPhantom() {
        let store = AccountRegistryStore(currentHash: "h")
        let uuids = (0..<8).map { "uuid-\($0)" }
        let pool = uuids.map { Self.makeAccount($0) } // pre-create on main (see churn test)
        let mismatch = CoherenceBox(), lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 300) { i in
            if i % 2 == 0 {
                store.mutate { $0["h"] = pool.shuffledStable(seed: i) }
            } else {
                let want = uuids[i % uuids.count]
                if let got = store.account(want), got.uuid != want {
                    lock.lock(); mismatch.flag = true; lock.unlock()
                }
            }
        }
        _ = store._coherentSnapshot() // drain pending barriers before teardown
        XCTAssertFalse(mismatch.flag, "account(uuid) must never return an Account with a different uuid")
    }

    /// Contract: slim writes back `account(_:)`'s fallback but MUST NOT flip
    /// `currentBucketIsLoaded` (which reflects the FULL list only — a truncated-picker
    /// guard); a full `mutate` DOES flip it.
    ///
    /// Kill case: let slim writes touch `accountSets`/`accountByUUID` → the ~2-account
    /// slim set reports the picker as loaded.
    func testSlim_backsFallbackButDoesNotFlipCurrentBucketIsLoaded() {
        let store = AccountRegistryStore(currentHash: "h")

        store.storeSlim([Self.makeAccount("slim-1")])
        XCTAssertNotNil(store.account("slim-1"), "slim account resolves as the pre-materialization fallback")
        XCTAssertFalse(store.currentBucketIsLoaded(), "slim writes must NOT flip currentBucketIsLoaded true")
        XCTAssertTrue(store.accounts(forKey: "h").isEmpty, "slim writes must NOT populate the full bucket")

        store.mutate { $0["h"] = [Self.makeAccount("full-1")] }
        XCTAssertTrue(store.currentBucketIsLoaded(), "a full mutate flips currentBucketIsLoaded true")
    }

    /// Contract (DETERMINISTIC): `accountsForCurrentHash` / `currentBucketIsLoaded`
    /// reflect the CURRENT hash's bucket — following `setCurrentHash`, the reads track
    /// the new hash (barrier FIFO makes the sync read observe the barrier-write seed).
    ///
    /// Kill case: a mutant that reads a hardcoded/other hash instead of `_currentHash`,
    /// or that never re-reads the hash after a switch → the assertions below (which
    /// flip between a loaded and an empty bucket as the current hash moves) fail.
    ///
    /// NOTE on the Finding-1 two-lock split: `accountsForCurrentHash` reads `_currentHash`
    /// and its bucket in ONE `performRead`, so the hash+bucket pairing is atomic BY
    /// CONSTRUCTION. A split (`accounts(forKey: currentHash)`) tears only under a
    /// specific concurrent interleaving and — because a split is still internally
    /// self-consistent (it returns the bucket for the hash it sampled) — is not
    /// deterministically observable from outside. That protection is therefore
    /// structural (single critical section) + code-reviewed, not asserted here; this
    /// test pins the current-hash CORRECTNESS the atomic method must have.
    func testCurrentHashReads_reflectTheCurrentHashsBucket() {
        let store = AccountRegistryStore(currentHash: "A")
        store.mutate { $0["A"] = [Self.makeAccount("a-1")]; $0["B"] = [] } // A loaded, B empty

        store.setCurrentHash("A")
        XCTAssertEqual(store.accountsForCurrentHash().map(\.uuid), ["a-1"],
                       "current is A → A's bucket")
        XCTAssertTrue(store.currentBucketIsLoaded(), "current is A (loaded) → loaded")

        store.setCurrentHash("B")
        XCTAssertTrue(store.accountsForCurrentHash().isEmpty,
                      "current is B (empty) → empty bucket, NOT A's stale contents")
        XCTAssertFalse(store.currentBucketIsLoaded(),
                       "current is B (empty) → not loaded, NOT A's stale readiness")
    }

    /// Robustness: under concurrent switching + reads, `accountsForCurrentHash` never
    /// crashes and never returns a TORN bucket (a mix of two libraries' accounts). Both
    /// buckets are seeded distinctly, so a torn read would surface a foreign/mixed uuid
    /// set. Kills an unsynchronized bucket read (outside `performRead`).
    func testCurrentHashReads_neverTearUnderConcurrentSwitch() {
        let store = AccountRegistryStore(currentHash: "A")
        let a = Self.makeAccount("a-1"), b = Self.makeAccount("b-1") // pre-create on main
        store.mutate { $0["A"] = [a]; $0["B"] = [b] }
        _ = store.currentBucketIsLoaded() // barrier fence — buckets populated before churn

        let torn = CoherenceBox(), lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 300) { i in
            if i % 2 == 0 {
                store.setCurrentHash(i % 4 == 0 ? "A" : "B")
            } else {
                let uuids = Set(store.accountsForCurrentHash().map(\.uuid))
                if !(uuids == ["a-1"] || uuids == ["b-1"] || uuids.isEmpty) {
                    lock.lock(); torn.flag = true; lock.unlock()
                }
            }
        }
        _ = store.currentBucketIsLoaded() // drain pending barriers before teardown
        XCTAssertFalse(torn.flag, "accountsForCurrentHash must return exactly one library's bucket, never a torn mix")
    }

    // MARK: - Routing (hub delegation)

    /// Contract: the hub's `account(_:)`, `accounts()`, and `accountsHaveLoaded`
    /// facades delegate to the injected store — data placed in the store post-construction
    /// is observable through the manager.
    ///
    /// Kill case: a facade that reads hub-local state instead of the store → the
    /// store-injected data is invisible.
    func testManagerFacades_delegateToInjectedStore() {
        let store = AccountRegistryStore()
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults(), registryStore: store)

        // Drive state through the store AFTER construction (init seeds its own hash).
        store.setCurrentHash("routing-h")
        store.mutate { $0["routing-h"] = [Self.makeAccount("routed-1")] }

        XCTAssertEqual(manager.account("routed-1")?.uuid, "routed-1",
                       "manager.account must delegate to the injected store")
        XCTAssertEqual(manager.accounts().map(\.uuid), ["routed-1"],
                       "manager.accounts() must delegate to the injected store's current bucket")
        XCTAssertTrue(manager.accountsHaveLoaded,
                      "manager.accountsHaveLoaded must delegate to the injected store")
    }

    // MARK: - Helpers

    /// Link-less account whose `metadata.id` is the uuid; no network on any drive.
    nonisolated static func makeAccount(_ uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "registry-store seam",
            id: uuid,
            title: "Store \(uuid)"
        )
        return Account(publication: OPDS2Publication(links: [], metadata: metadata, images: nil),
                       imageCache: MockImageCache())
    }
}

/// `@unchecked Sendable` flag holder for cross-thread test assertions (guarded by the
/// test's own `NSLock`).
fileprivate final class CoherenceBox: @unchecked Sendable {
    var flag = false
}

private extension Array {
    /// Deterministic index-driven rotation (no `Math.random`, which is unavailable in
    /// some harness contexts) so each round reseeds a different order.
    func shuffledStable(seed: Int) -> [Element] {
        guard !isEmpty else { return self }
        let k = seed % count
        return Array(self[k...] + self[..<k])
    }
}
