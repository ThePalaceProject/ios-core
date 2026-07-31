//
//  AccountRegistryStore.swift
//  Palace
//
//  god-class decomposition — Wave 3 / 3a-2 (the second in-target collaborator
//  split out of `AccountsManager`).
//
//  Owns the account-registry STATE and all thread-safe access to it: the current
//  catalog hash, the `[hash → [Account]]` sets, the O(1) `uuid → Account` index kept
//  in lockstep with them, and the separate slim launch-hydration fallback. Extracted
//  behind an injected collaborator so the hub carries no registry-state concurrency
//  machinery and a packaged `AccountsManager` names none of it — the
//  `AccountRegistryCache` / `AccountStateStore` precedent.
//
//  A `final class`, NOT an `actor`, and NOT a protocol: `AccountsManager.account(_:)`
//  is a SYNCHRONOUS `@objc TPPLibraryAccountsProvider` requirement, and the
//  background-work drain choreography (`cancelAndDrainBackgroundWork`) depends on a
//  synchronous `accountSetsLock.sync` read blocking behind the barrier — an actor
//  would force `await` through the `@objc` conformance and delete that timing. The
//  store therefore OWNS the same concurrent `DispatchQueue` and preserves the exact
//  sync-read / `.async(flags:.barrier)`-write model verbatim. It is pure in-target
//  state with no outward app-target edge, so it is a concrete injected instance
//  (like `AccountStateStore`) and travels into `PalaceAccounts` with the hub.
//
//  `@unchecked Sendable` invariant: the only mutable state is `_currentHash`,
//  `accountSets`, and `accountByUUID`, read exclusively via `accountSetsLock.sync`
//  (`performRead`) and written exclusively on the serial `.barrier` of the concurrent
//  `accountSetsLock` (`performWrite` / `mutate`); `accountByUUID` is rebuilt inside the
//  SAME barrier as `accountSets` so the two never desync. `slimAccountsByUUID` is
//  guarded by its own `slimAccountsLock` NSLock — deliberately separate so the
//  `account(_:)` full-index read and the slim fallback never contend on one lock; the
//  slim set is a launch fallback only and never flips `currentBucketIsLoaded`. All
//  boxed closures are invoked exactly once on that serial barrier, never concurrently.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Documented carrier for a non-Sendable `() -> Void` handed to the `accountSetsLock`
/// barrier in `performWrite`. `@unchecked Sendable` invariant: the wrapped closure is
/// invoked exactly once, on the serial barrier of the concurrent `accountSetsLock`,
/// never concurrently.
private struct VoidWorkBox: @unchecked Sendable {
    let work: () -> Void
}

/// Documented carrier for the non-Sendable `(inout [String: [Account]]) -> Void`
/// mutation closure handed to the `accountSetsLock` barrier in `mutate`. Same
/// `@unchecked Sendable` invariant as `VoidWorkBox`: invoked exactly once, on the
/// serial `.barrier`, never concurrently. Timing and the mutate-then-rebuild-index
/// contract are unchanged.
private struct AccountSetsMutationBox: @unchecked Sendable {
    let mutate: (inout [String: [Account]]) -> Void
}

/// Thread-safe holder of the account-registry state. See the file header for the
/// `@unchecked Sendable` invariant and the class-not-actor rationale.
final class AccountRegistryStore: @unchecked Sendable {

    /// The current catalog hash (`prod` / `beta` / custom-URL). Written on the
    /// barrier, read under `accountSetsLock` — bundled into ONE critical section with
    /// the bucket read by `accountsForCurrentHash` / `currentBucketIsLoaded` so a
    /// concurrent library switch can never key the bucket to a stale hash.
    private var _currentHash: String

    private var accountSets = [String: [Account]]()

    /// O(1) `uuid → Account` index derived from `accountSets`, kept in lockstep with
    /// it under `accountSetsLock` (rebuilt in the SAME barrier as any `accountSets`
    /// mutation — see `mutate`). Lets `account(_:)` resolve a UUID without a linear
    /// scan over ~1142 accounts on the main-thread display path. MUST only change via
    /// `mutate` so it can never desync from `accountSets`.
    private var accountByUUID = [String: Account]()

    private let accountSetsLock = DispatchQueue(label: "com.tpp.accountSetsLock", attributes: .concurrent)

    /// Launch-hydration (CP-D1) slim lookup: the current + settings accounts (~2),
    /// decoded synchronously at launch so `currentAccount` resolves within a few ms.
    /// Deliberately SEPARATE from `accountSets`: the slim set backs `account(_:)`'s
    /// FALLBACK only and MUST NOT flip `currentBucketIsLoaded` true (a truncated-picker
    /// bug). Guarded by its own `NSLock` so the `account(_:)` `accountSetsLock` read and
    /// this fallback never contend on the same lock.
    private var slimAccountsByUUID = [String: Account]()
    private let slimAccountsLock = NSLock()

    init(currentHash: String = "") {
        self._currentHash = currentHash
    }

    // MARK: - Concurrency primitives (private)

    private func performRead<T>(_ block: () -> T) -> T {
        return accountSetsLock.sync {
            block()
        }
    }

    private func performWrite(_ block: @escaping () -> Void) {
        let box = VoidWorkBox(work: block)
        accountSetsLock.async(flags: .barrier) {
            box.work()
        }
    }

    // MARK: - Current hash

    /// Single synchronized read of the current hash, for callers that need only the
    /// hash (never paired atomically with a bucket read — those use the atomic
    /// methods below).
    var currentHash: String {
        performRead { self._currentHash }
    }

    func setCurrentHash(_ hash: String) {
        performWrite { self._currentHash = hash }
    }

    // MARK: - Reads

    func account(_ uuid: String) -> Account? {
        if let full = performRead({ accountByUUID[uuid] }) {
            return full
        }
        // CP-D1 launch-hydration fallback: before the full account list has
        // materialized off-main, the slim snapshot backs current-account resolution.
        // Full instances take precedence (checked first, above) once present.
        return slimAccount(uuid)
    }

    /// Accounts for an explicit hash. Used by callers that already hold the hash they
    /// want (the hub `accounts(key)` facade when a key is passed, plus tests).
    func accounts(forKey key: String) -> [Account] {
        performRead { self.accountSets[key] ?? [] }
    }

    /// Accounts for the CURRENT hash, read ATOMICALLY: the hash and the bucket are
    /// sampled in ONE `performRead`, so a library-switch barrier cannot land between
    /// them and key the bucket to a stale hash. Do NOT reimplement as
    /// `accounts(forKey: currentHash)` — that is two separate lock acquisitions.
    func accountsForCurrentHash() -> [Account] {
        performRead { self.accountSets[self._currentHash] ?? [] }
    }

    /// Whether the CURRENT hash's bucket is non-empty, read ATOMICALLY (same
    /// single-critical-section snapshot as `accountsForCurrentHash`). Reflects the
    /// FULL account list only — the slim fallback never flips this true.
    func currentBucketIsLoaded() -> Bool {
        performRead { !(self.accountSets[self._currentHash]?.isEmpty ?? true) }
    }

    /// Whether an explicit hash's bucket is non-empty.
    func bucketIsNonEmpty(hash: String) -> Bool {
        performRead { self.accountSets[hash]?.isEmpty == false }
    }

    // MARK: - Writes

    /// The ONLY sanctioned way to mutate `accountSets`. Applies `mutate` inside the
    /// `accountSetsLock` barrier, then rebuilds `accountByUUID` in the SAME critical
    /// section so the two can never desync. Adding a write that bypasses this silently
    /// breaks `account(_:)` lookups (guarded by the index-coherence tests).
    func mutate(_ mutate: @escaping (inout [String: [Account]]) -> Void) {
        let box = AccountSetsMutationBox(mutate: mutate)
        accountSetsLock.async(flags: .barrier) {
            box.mutate(&self.accountSets)
            self.accountByUUID = AccountRegistryStore.buildAccountIndex(self.accountSets)
        }
    }

    // MARK: - Slim launch-hydration fallback

    func storeSlim(_ accounts: [Account]) {
        slimAccountsLock.lock()
        defer { slimAccountsLock.unlock() }
        for account in accounts {
            slimAccountsByUUID[account.uuid] = account
        }
    }

    func slimAccount(_ uuid: String) -> Account? {
        slimAccountsLock.lock()
        defer { slimAccountsLock.unlock() }
        return slimAccountsByUUID[uuid]
    }

    // MARK: - Pure

    /// Pure: flatten `accountSets` into a `uuid → Account` index. When a UUID appears
    /// in more than one bucket, the last-enumerated wins — equivalent to the
    /// nondeterministic "first across `values`" the prior linear scan returned.
    static func buildAccountIndex(_ sets: [String: [Account]]) -> [String: Account] {
        var index = [String: Account]()
        for accounts in sets.values {
            for account in accounts {
                index[account.uuid] = account
            }
        }
        return index
    }

    #if DEBUG
    /// Test-only: reads `accountByUUID` and a freshly-rebuilt index in ONE
    /// `performRead` and returns whether they are identical (by key set + object
    /// identity). A mutant that rebuilds the index outside the mutation barrier opens
    /// a window where a sync read observes updated `accountSets` but a stale
    /// `accountByUUID`; hammering this under concurrent `mutate` catches it.
    func _coherentSnapshot() -> Bool {
        performRead {
            let rebuilt = AccountRegistryStore.buildAccountIndex(self.accountSets)
            guard rebuilt.count == self.accountByUUID.count else { return false }
            for (uuid, account) in rebuilt {
                guard let indexed = self.accountByUUID[uuid], indexed === account else { return false }
            }
            return true
        }
    }
    #endif
}
