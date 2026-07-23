# Transcript — BookRegistryInfra (swarm_ad0b4c65, Wave 1, CRITICAL-PATH)

Worked in worktree `.claude/worktrees/swarm_ad0b4c65-bookregistry` on branch
`swarm/swarm_ad0b4c65-bookregistry` (develop tip `a3c9d1f31`). Read develop's
ACTUAL current files fresh (not the stale 210-behind prior attempt).

## Files changed (2 — exactly the in-scope set; nothing else touched)
- `Palace/Book/Models/BookRegistryStore.swift`  (+21)
- `Palace/Book/Models/TPPBookRegistry.swift`    (+27)

No test files, no other `Palace/**` files. Not committed, not pushed — left in
the worktree working tree for the integrator.

## S1 — `BookRegistryStore._awaitPendingWritesForTesting()`
Placed right after the `performBarrierSync` helper (new `// MARK: - Test-only
deterministic-join seam`). Added code:

```swift
func _awaitPendingWritesForTesting() async {
  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    performBarrier { cont.resume() }
  }
}
```

**Real barrier primitive adapted:** develop's store is a **concurrent**
`DispatchQueue` (`attributes: .concurrent`, label `com.palace.bookRegistryStore`)
and every mutation goes through `performBarrier(_ block: @escaping () -> Void)`
which does `syncQueue.async(flags: .barrier) { carrier.run() }`. The contract's
guessed name matched. All of `addBook`/`removeBook`/`updateBook`/`updateAndRemoveBook`/
`setState`/`setProcessing` enqueue via `performBarrier`.

**Why bounded:** a `.barrier` job on a concurrent queue is FIFO and mutually
exclusive with all other work — it starts only after every previously-enqueued
barrier write block (and the `onComplete` invoked inside it) has fully finished.
So the trailing `performBarrier { cont.resume() }` is guaranteed to run, exactly
once, after the drain. It is NOT a bare `await handle` (no external Task/future
that could be cancelled/never-resumed) and introduces no sleep/poll/Date/Timer —
it only drains the already-existing queue. No XCTest gate needed: it retains no
state and production never calls it (mirrors the *intent* of the canonical seams,
which only need their gate because they RETAIN task handles; this one does not).

## S2 — `TPPBookRegistry._awaitPendingWritesForTesting()`
Placed after `updatedBookMetadata(_:)` (new `// MARK: - Test-only
deterministic-join seam`). Registry holds `private let store: BookRegistryStore`
(line 209) — the seam is an instance method inside the class so it reaches the
private `store` directly; no new accessor / no `.shared` reach-through needed.
Added code:

```swift
func _awaitPendingWritesForTesting() async {
  await store._awaitPendingWritesForTesting()
  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    DispatchQueue.main.async { cont.resume() }
  }
}
```

**Why bounded (two stages):**
1. Stage 1 forwards to S1 (itself bounded, above) — drains the write barrier.
   The store's `registry` `didSet` posts its snapshot broadcast via
   `DispatchQueue.main.async` (BookRegistryStore line 41), and the registry's own
   per-mutation `store.bookStateSubject.send(...)` re-broadcasts hop through
   `DispatchQueue.main.async` (TPPBookRegistry ~617/633/648/661/682). Both are
   enqueued *synchronously inside* the barrier blocks, so they are all enqueued
   on the main queue BEFORE S1's trailing barrier completes.
2. Stage 2 does one `DispatchQueue.main.async` hop. By FIFO ordering on the main
   queue it runs strictly after every broadcast enqueued in stage 1, then resumes
   the continuation exactly once. Again: no bare `await`, no sleep/poll/clock.

Deliberately does NOT await the account switch-back debounce (`asyncAfter`
~line 160) — that is a UX timer, not fire-and-forget work; tests that assert
switch-back drive it explicitly (per contract).

## Grep evidence (contract §Verification)
1. Two defs exist:
   - `BookRegistryStore.swift:110: func _awaitPendingWritesForTesting() async {`
   - `TPPBookRegistry.swift:725: func _awaitPendingWritesForTesting() async {`
2. Every added `await` is one of the two allowed shapes (withCheckedContinuation
   resumed from a barrier/main hop, or S1):
   - `BookRegistryStore.swift:111: await withCheckedContinuation { ... performBarrier { cont.resume() } }`
   - `TPPBookRegistry.swift:726:  await store._awaitPendingWritesForTesting()`
   - `TPPBookRegistry.swift:727:  await withCheckedContinuation { ... DispatchQueue.main.async { cont.resume() } }`
   No bare `await someHandle.value`.
3. No new clock on added lines: `git diff | grep '^+' | grep -E 'sleep|asyncAfter|Date\(\)|Timer'`
   returns only three `///` COMMENT lines (documenting the absence, and naming the
   deliberately-not-awaited `asyncAfter`) — zero added executable clock code.
4. Build: CI-gated. This worktree lacks Carthage binaries + the submodule, so a
   local `xcodebuild` is not possible; did not spin on it. Verified via grep
   criteria above.
5. Not public: `grep 'public func _await' <files>` → empty. Both seams are
   `internal` (reachable via `@testable import Palace`), documented test-only.

## Full diff
See `scratchpad/seam.diff` (70 lines, +48 net).
