# Contract — BookRegistryInfra (Wave 1, risk: critical_path)

## Goal
Add two deterministic test-join seams so tests never wall-clock-wait on the
registry's barrier-queue writes or its main-thread broadcast hops. **Prod-only —
no test files change in this contract.** Highest fan-in (Book, BookRegistry,
MyBooks, Holds, BookStateManagement, Sync, Bookmarks depend on these).

## Files in scope (edit ONLY these)
- `Palace/Book/Models/BookRegistryStore.swift`
- `Palace/Book/Models/TPPBookRegistry.swift`

## OFF-LIMITS
- Every `PalaceTests/**` file (Wave 2 converts call sites, not this contract).
- Any other `Palace/**` file. If you find you need to touch one, STOP and report.

## Seams to add

### S1 — `BookRegistryStore._awaitPendingWritesForTesting() async`
The store serializes mutations on a barrier queue (see `performBarrier(...)`,
~line 193). A trailing barrier is bounded by construction: a FIFO barrier block
runs only after every previously-enqueued `addBook`/`removeBook`/`updateBook`
block (and its `onComplete`) has finished. Enqueue one and await it:
```swift
/// Test-only: await all writes enqueued before this call. Bounded — a FIFO
/// barrier block runs only after every prior mutation block has completed.
/// No XCTest gate needed: this spawns NO retained state, it only drains the
/// existing queue (production never calls it).
func _awaitPendingWritesForTesting() async {
    await withCheckedContinuation { cont in
        performBarrier { cont.resume() }
    }
}
```
- If `performBarrier`'s real name/signature differs, adapt to the actual barrier
  primitive — the REQUIREMENT is "enqueue a trailing block on the same serial/
  barrier queue and resume the continuation from it." Do NOT add a sleep/poll.
- Keep it `internal` (reachable via `@testable import Palace`), documented test-only.

### S2 — `TPPBookRegistry._awaitPendingWritesForTesting() async`
Forwards to S1, then drains the registry's own `DispatchQueue.main.async`
state-broadcast hops (the notification/`@Published` re-broadcasts, ~lines
617/633/648/661/682) by awaiting one main-queue hop:
```swift
/// Test-only: await the store's pending writes (S1) THEN one main-queue hop so
/// the registry's state broadcasts have been delivered. Deliberately does NOT
/// await the intrinsic account switch-back debounce (asyncAfter ~line 160) —
/// that is a UX timer, not fire-and-forget work; tests asserting switch-back
/// drive it explicitly.
func _awaitPendingWritesForTesting() async {
    await store._awaitPendingWritesForTesting()   // adapt to the actual store accessor
    await withCheckedContinuation { cont in
        DispatchQueue.main.async { cont.resume() }
    }
}
```
- Adapt `store.` to however `TPPBookRegistry` references its `BookRegistryStore`.
- If the registry is an `@objc`/singleton with no direct store handle in a
  testable scope, expose the minimal internal accessor needed (document it
  test-only) rather than reaching through `.shared`.

## Verification criteria (grep-able; paste evidence)
1. Both seams exist and compile:
   `grep -n '_awaitPendingWritesForTesting' Palace/Book/Models/BookRegistryStore.swift Palace/Book/Models/TPPBookRegistry.swift` → 2 defs.
2. **No unbounded await introduced:** each seam's `await` targets either a
   `withCheckedContinuation` resumed from a barrier/main hop, or S1. `grep -n
   'await' <files>` — every await is one of those two shapes; NO bare
   `await someHandle.value` on a handle that may never resume.
3. **No new clock:** `grep -nE 'sleep|asyncAfter|Date\(\)|Timer' ` on the ADDED
   lines returns nothing (the added seams introduce no delay).
4. Build the app target compiles (CI-gated; if you can build locally, paste the
   tail; otherwise state "CI-gated build" honestly).
5. Seams are `internal`/test-documented, not `public`: `grep -n 'public func _await' <files>` → empty.

## Notes for the implementer
- Mirror the canonical existing seams for tone/placement: `AccountsManager
  ._awaitAllCrawlTasksForTesting`, `TokenRefreshInterceptor._awaitAuthDispatchForTesting`.
- This contract adds NO tests (it's infra). Wave-2 contracts consume these seams.
- Do NOT commit; leave staged for the integrator. Write your transcript to
  `.forgeos/swarms/swarm_ad0b4c65/transcripts/BookRegistryInfra.md`.
