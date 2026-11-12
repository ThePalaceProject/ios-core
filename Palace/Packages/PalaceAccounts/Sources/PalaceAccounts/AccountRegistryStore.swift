//
//  AccountRegistryStore.swift
//  PalaceAccounts
//
//  Account-registry state (catalog hash, account sets, `uuid → Account` index,
//  slim launch fallback) and thread-safe access to it. Generic over the entry
//  type so the package does not name the app-target `Account`; the app uses
//  `AccountRegistryStore<Account>`. A class, not an actor:
//  `AccountsManager.account(_:)` is a synchronous `@objc` requirement. Writes are
//  synchronous under `accountSetsLock`, giving read-after-write ordering; the
//  slim set has its own lock. `@unchecked Sendable` on that basis.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// What the registry store needs from an account: reference identity (the
/// index-coherence check compares with `===`) and a stable `uuid` key.
// PUBLIC_INTENT: the app's Account adopts this as the store's entry type.
public protocol AccountRegistryEntry: AnyObject {
    var uuid: String { get }
}

/// Carries non-Sendable values into the write critical section.
/// `@unchecked Sendable`: each is used exactly once, under the
/// `accountSetsLock` write lock, never concurrently.
private struct VoidWorkBox: @unchecked Sendable {
    let work: () -> Void
}

private struct AccountsReplacementBox<Entry>: @unchecked Sendable {
    let accounts: [Entry]
}

private struct AccountSetsMutationBox<Entry>: @unchecked Sendable {
    let mutate: (inout [String: [Entry]]) -> Void
}

/// Reader/writer lock the CALLING thread takes itself.
///
/// Not `DispatchQueue.sync` + `.barrier`: a queued barrier needs a GCD worker
/// thread, and Swift Task readers blocked in `.sync` each hold a
/// cooperative-pool thread (pool width == core count), so enough readers park
/// every thread the barrier needs. `pthread_rwlock` is acquired by the caller
/// directly and needs no worker thread.
private final class ReadWriteLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()

    init() { pthread_rwlock_init(&lock, nil) }
    deinit { pthread_rwlock_destroy(&lock) }

    func read<T>(_ block: () -> T) -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return block()
    }

    func write<T>(_ block: () -> T) -> T {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return block()
    }
}

/// Thread-safe holder of the account-registry state. See the file header.
// PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
public final class AccountRegistryStore<Entry: AccountRegistryEntry>: @unchecked Sendable {

    /// The current catalog hash (`prod` / `beta` / custom-URL). Written on the
    /// write lock, read under it — bundled into ONE critical section with
    /// the bucket read by `accountsForCurrentHash` / `currentBucketIsLoaded` so a
    /// concurrent library switch can never key the bucket to a stale hash.
    private var _currentHash: String

    private var accountSets = [String: [Entry]]()

    /// O(1) `uuid → Account` index derived from `accountSets`, kept in lockstep with
    /// it under `accountSetsLock` (rebuilt in the SAME write critical section as any `accountSets`
    /// mutation — see `mutate`). Lets `account(_:)` resolve a UUID without a linear
    /// scan over ~1142 accounts on the main-thread display path. MUST only change via
    /// `mutate` so it can never desync from `accountSets`.
    private var accountByUUID = [String: Entry]()

    /// Guards `_currentHash` / `accountSets` / `accountByUUID`. Taken directly by
    /// the calling thread — see `ReadWriteLock` for why this is not a queue.
    private let accountSetsLock = ReadWriteLock()

    /// Launch-hydration slim lookup: the current + settings accounts (~2),
    /// decoded synchronously at launch so `currentAccount` resolves within a few ms.
    /// Deliberately SEPARATE from `accountSets`: the slim set backs `account(_:)`'s
    /// FALLBACK only and MUST NOT flip `currentBucketIsLoaded` true (a truncated-picker
    /// bug). Guarded by its own `NSLock` so the `account(_:)` `accountSetsLock` read and
    /// this fallback never contend on the same lock.
    private var slimAccountsByUUID = [String: Entry]()
    private let slimAccountsLock = NSLock()

    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public init(currentHash: String = "") {
        self._currentHash = currentHash
    }

    // MARK: - Concurrency primitives (private)

    private func performRead<T>(_ block: () -> T) -> T {
        return accountSetsLock.read {
            block()
        }
    }

    private func performWrite(_ block: @escaping () -> Void) {
        let box = VoidWorkBox(work: block)
        accountSetsLock.write {
            box.work()
        }
    }

    // MARK: - Current hash

    /// Single synchronized read of the current hash, for callers that need only the
    /// hash (never paired atomically with a bucket read — those use the atomic
    /// methods below).
    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public var currentHash: String {
        performRead { self._currentHash }
    }

    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func setCurrentHash(_ hash: String) {
        performWrite { self._currentHash = hash }
    }

    // MARK: - Reads

    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func account(_ uuid: String) -> Entry? {
        if let full = performRead({ accountByUUID[uuid] }) {
            return full
        }
        // Launch-hydration fallback: before the full account list has
        // materialized off-main, the slim snapshot backs current-account resolution.
        // Full instances take precedence (checked first, above) once present.
        return slimAccount(uuid)
    }

    /// Accounts for an explicit hash. Used by callers that already hold the hash they
    /// want (the hub `accounts(key)` facade when a key is passed, plus tests).
    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func accounts(forKey key: String) -> [Entry] {
        performRead { self.accountSets[key] ?? [] }
    }

    /// Accounts for the CURRENT hash, read ATOMICALLY: the hash and the bucket are
    /// sampled in ONE `performRead`, so a library-switch write cannot land between
    /// them and key the bucket to a stale hash. Do NOT reimplement as
    /// `accounts(forKey: currentHash)` — that is two separate lock acquisitions.
    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func accountsForCurrentHash() -> [Entry] {
        performRead { self.accountSets[self._currentHash] ?? [] }
    }

    /// Whether the CURRENT hash's bucket is non-empty, read ATOMICALLY (same
    /// single-critical-section snapshot as `accountsForCurrentHash`). Reflects the
    /// FULL account list only — the slim fallback never flips this true.
    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func currentBucketIsLoaded() -> Bool {
        performRead { !(self.accountSets[self._currentHash]?.isEmpty ?? true) }
    }

    /// Whether an explicit hash's bucket is non-empty.
    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func bucketIsNonEmpty(hash: String) -> Bool {
        performRead { self.accountSets[hash]?.isEmpty == false }
    }

    // MARK: - Writes

    /// The ONLY sanctioned way to mutate `accountSets`. Applies `mutate` inside the
    /// `accountSetsLock` write lock, then rebuilds `accountByUUID` in the SAME critical
    /// section so the two can never desync. Adding a write that bypasses this silently
    /// breaks `account(_:)` lookups (guarded by the index-coherence tests).
    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func mutate(_ mutate: @escaping (inout [String: [Entry]]) -> Void) {
        let box = AccountSetsMutationBox(mutate: mutate)
        // Index rebuilt inside the SAME critical section as the mutation, so a
        // reader can never observe updated `accountSets` with a stale
        // `accountByUUID` (pinned by the index-coherence tests).
        accountSetsLock.write {
            box.mutate(&self.accountSets)
            self.accountByUUID = AccountRegistryStore.buildAccountIndex(self.accountSets)
        }
    }

    /// PP-5191. Replace `hash`'s bucket, refusing a write that would lose
    /// libraries. Returns whether it applied.
    ///
    /// > A write that removes no uuids the resident bucket holds is always applied.
    /// > A write that removes uuids is applied only against positively-asserted
    /// > completeness (`metadata.numberOfItems != nil && count == numberOfItems`).
    ///
    /// The rule is about information loss, not a partial/complete label: a merged
    /// page-1 superset (partial) must still replace a smaller complete bundled
    /// snapshot.
    ///
    /// `count >=` is not an acceptable proxy for "removes nothing": equal counts can
    /// still drop uuids under churn. The resident set is read from `accountSets[hash]`
    /// and NOT from `accountByUUID`, which flattens every bucket and would compare
    /// against other hashes' libraries.
    ///
    /// Scope of the guarantee: the resident bucket is empty on the FIRST write of any
    /// launch, so this cannot fire then — it guards in-session transitions. The
    /// across-launch guarantee is that callers never write a lossy feed to disk.
    ///
    /// Lock composition: ONE `accountSetsLock.write`, doing read → decide → mutate →
    /// rebuild-index inside a single critical section. It must never call `mutate`
    /// (recursive `wrlock` on a non-recursive pthread lock = deadlock on the launch
    /// thread) nor pair `performRead` with a later `mutate` (TOCTOU against the owned
    /// crawl tasks).
    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func replaceBucket(hash: String, accounts: [Entry], isCompleteFeed: Bool) -> Bool {
        let box = AccountsReplacementBox(accounts: accounts)
        return accountSetsLock.write {
            let resident = self.accountSets[hash] ?? []
            if !resident.isEmpty && !isCompleteFeed {
                let incoming = Set(box.accounts.map(\.uuid))
                let removed = resident.filter { !incoming.contains($0.uuid) }
                if !removed.isEmpty {
                    Log.error(#file, "INV-2: refusing a lossy registry write for hash \(hash) — resident \(resident.count), incoming \(box.accounts.count), would drop \(removed.count) librar\(removed.count == 1 ? "y" : "ies") and the feed is not positively complete")
                    return false
                }
            }
            self.accountSets[hash] = box.accounts
            self.accountByUUID = AccountRegistryStore.buildAccountIndex(self.accountSets)
            return true
        }
    }

    // MARK: - Slim launch-hydration fallback

    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func storeSlim(_ accounts: [Entry]) {
        slimAccountsLock.lock()
        defer { slimAccountsLock.unlock() }
        for account in accounts {
            slimAccountsByUUID[account.uuid] = account
        }
    }

    // PUBLIC_INTENT: AccountsManager and AccountRegistryLoader (app target) hold and drive the store.
    public func slimAccount(_ uuid: String) -> Entry? {
        slimAccountsLock.lock()
        defer { slimAccountsLock.unlock() }
        return slimAccountsByUUID[uuid]
    }

    // MARK: - Pure

    /// Pure: flatten `accountSets` into a `uuid → Account` index. When a UUID appears
    /// in more than one bucket, the last-enumerated wins.
    // PUBLIC_INTENT: AccountsManager+TestingSupport (app target) forwards to it.
    public static func buildAccountIndex(_ sets: [String: [Entry]]) -> [String: Entry] {
        var index = [String: Entry]()
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
    /// identity). Rebuilding the index outside the write section would let a read
    /// see updated `accountSets` with a stale `accountByUUID`; calling this under
    /// concurrent `mutate` detects that.
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
