# Transcript — Wave-2 wall-clock-wait conversion, module BookRegistry (swarm_ad0b4c65)

Worked in worktree `.claude/worktrees/swarm_ad0b4c65-w2-bookregistry`, already on
the wave-1 seam commit (`b4e6ba841`), no new branch created. Scope:
`PalaceTests/BookRegistry/`, `PalaceTests/BookStateManagement/`,
`PalaceTests/Sync/` only. Cannot build locally (CI-gated) — grep-verified only,
evidence pasted below.

## First pass

```
$ grep -lE 'wait\(for:|waitForExpectations|fulfillment\(of:|Thread\.sleep|usleep|asyncAfter|while.*Date\(\)|awaitCondition|RunLoop.current.run' \
    PalaceTests/BookRegistry/*.swift PalaceTests/BookStateManagement/*.swift PalaceTests/Sync/*.swift
```

**9 of 17 files matched.** The other 8
(`TPPBookRegistryDependencyTests`, `TPPBookRegistryStateConcurrencyTests`,
`BookButtonMapperHoldReadyTests`, `BookButtonMapperTests`,
`BookCellModelCacheInvalidationTests`, `TPPBookRegistryRecordTests`,
`CrossDeviceSyncE2ETests`, `MockSyncBackend`) have **zero** wall-clock-wait
patterns. `PalaceTests/Sync/` in particular is already fully seam-clean — every
async wait in `CrossDeviceSyncE2ETests.swift` is a `withCheckedContinuation`
resumed directly from a real network/bookmark-service completion callback; no
`wait(for:)`/`RunLoop`/`sleep` anywhere in the directory.

## Files changed

**7 files converted; 2 files with matches reviewed and left byte-for-byte
(KEEP-only, see below).**

- `PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift`
- `PalaceTests/BookRegistry/TPPBookRegistryIntegrationTests.swift`
- `PalaceTests/BookRegistry/TPPBookRegistryLargeCorpusTests.swift`
- `PalaceTests/BookRegistry/TPPBookRegistryMigrationTests.swift`
- `PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift`
- `PalaceTests/BookRegistry/TPPBookRegistryTests.swift`
- `PalaceTests/BookStateManagement/BookCellModelStateTests.swift`

```
$ git diff --stat
 .../TPPBookRegistryAtomicWriteTests.swift          |  47 ++++---
 .../TPPBookRegistryIntegrationTests.swift          | 155 ++++++++++-----------
 .../TPPBookRegistryLargeCorpusTests.swift          |  45 +++---
 .../TPPBookRegistryMigrationTests.swift             |  89 ++++++------
 .../TPPBookRegistryPersistenceTests.swift          | 109 +++++++++------
 .../BookRegistry/TPPBookRegistryTests.swift        |  30 ++--
 .../BookCellModelStateTests.swift                  |  38 ++---
 7 files changed, 253 insertions(+), 260 deletions(-)
```

## Per-file before → after wait counts (functional occurrences, comments excluded)

| File | Before | CONVERT | KEEP | UNMAPPED | After |
|---|---|---|---|---|---|
| `TPPBookRegistryAtomicWriteTests.swift` | 3 | 2 | 0 | 1 | 1 |
| `TPPBookRegistryIntegrationTests.swift` | 10 | 10 | 0 | 0 | 0 |
| `TPPBookRegistryLargeCorpusTests.swift` | 2 | 2 | 0 | 0 | 0 |
| `TPPBookRegistryMigrationTests.swift` | 2 | 2 | 0 | 0 | 0 |
| `TPPBookRegistryPersistenceTests.swift` | 6 | 5 | 0 | 1 | 1 |
| `TPPBookRegistryTests.swift` | 2 | 2 | 0 | 0 | 0 |
| `BookCellModelStateTests.swift` | 2 | 2 | 0 | 0 | 0 |
| `BookCellModelActionTests.swift` (untouched) | 1 | 0 | 1 | 0 | 1 |
| `ButtonStateMonotonicClampTests.swift` (untouched) | 2 (1 logical) | 0 | 2 | 0 | 2 |
| **Total** | **30** | **25** | **3** | **2** | **5** |

Every row satisfies `Before = CONVERT + KEEP + UNMAPPED` and
`After = KEEP + UNMAPPED`. "Before" counts include `RunLoop.current.run(until:
Date(timeIntervalSinceNow:...))` settle-spins alongside `wait(for:)` /
`waitForExpectations` — that pattern is functionally a wall-clock wait
(equivalent to `Thread.sleep`) even though the playbook's example token list
doesn't name it explicitly; converted every instance found.

## Bounded-await citations (every seam join added)

All 25 CONVERTED sites target exactly one of two things:

**S1/S2 catalog seam:**
```swift
await store._awaitPendingWritesForTesting()          // BookRegistryStore (S1)
await registry._awaitPendingWritesForTesting()       // TPPBookRegistry   (S2)
```
Bounded by construction (per catalog): a trailing `.barrier` block on the
concurrent `syncQueue`, resumed via `CheckedContinuation` — runs only after
every previously-enqueued write (and its `onComplete`) has finished. Verified
by reading `BookRegistryStore.swift`'s `mutateRegistry`/`addBook`/`removeBook`/
`updateBook`/`setState` — every one funnels through `performBarrier` on the
same `syncQueue`, so a join after N writes drains all N regardless of which
facade (`BookRegistrySync.load`, `TPPBookRegistry.addBook`, etc.) issued them.

**Bounded main-queue-drain primitive** (pre-existing, read-only use):
```swift
await drainMainQueueAsync()
```
Used immediately after the seam join in every CONVERT, because the actual
`callbacks.setState(.loaded)` / `bookStateSubject.send(...)` /
`registrySubject.send(...)` calls are scheduled via
`DispatchQueue.main.async { ... }` **from inside** the barrier block the seam
just drained — the seam proves the dispatch was *submitted*, the drain proves
it *ran*. Confirmed this schedule-inside-barrier shape by reading
`BookRegistrySync.load` (L146-338), `BookRegistryStore.setState`/`updateBook`/
`registry`'s `didSet` (L36-42, 308-314, 239-246).

Two tests (`BookCellModelStateTests.swift`) needed **only**
`drainMainQueueAsync()` with no seam — `BookCellModel`'s subscription to
`downloadCenter.downloadErrorPublisher` uses `.receive(on: DispatchQueue.main)`
directly on a synchronous `.send()`, no barrier queue involved at all.

**No bare unbounded `await` was introduced anywhere.** Every `await` added is
either the S1/S2 seam or the pre-existing `drainMainQueueAsync()` primitive
from `XCTestCase+drainMainQueue.swift` (read-only — not edited).

## Notable conversions (beyond the mechanical `loadAndWait()` helpers)

- **`TPPBookRegistryPersistenceTests.testBookStatePublisher_DoesNotFireOnNoOpUpdateBook`**:
  previously asserted absence via two fixed RunLoop spins (0.2s "let addBook
  settle" + 0.5s "wait to see if updateBook spuriously fires"). Traced
  `TPPBookRegistry.updateBook` → `store.updateBook(...) { prev, next, _ in if
  next != prev { DispatchQueue.main.async {...} } }` — the decision to
  schedule the publish is made **synchronously inside the barrier**, so for a
  genuine no-op the dispatch is never scheduled at all. Replaced both spins
  with seam joins: strictly *more* deterministic than the original 0.5s guess,
  not just faster.
- **`TPPBookRegistryTests.testLoad_EmitsBookStateEventsForAllBooks`**: this
  test drives the real `AppContainer.production()` singleton (pre-existing,
  not introduced by this wave) — left that architecture as-is per scope, only
  converted the wait mechanism (fixed 0.5s pre-test RunLoop spin → bounded
  `drainMainQueueAsync()`; `.first().sink{fulfill()}` + `wait(for:timeout:5)`
  → S2 seam + drain).
- **`TPPBookRegistryIntegrationTests`** (`TPPBookRegistryPublisherTests` +
  `TPPBookRegistryThreadSafetyTests`, 10 sites): every
  `.filter{}.first().sink{expectation.fulfill()}` + `waitForExpectations(...)`
  triplet replaced with a plain capturing `.sink{}` + seam join + direct
  assertion. Multi-write tests (`testBookStatePublisher_MultipleStateChanges_EmitsAll`,
  the two Crashlytics-30c41d7e regression tests, the 15-mutation snapshot-
  consistency test) issue several writes before a single join — safe because
  every write funnels through the SAME store `syncQueue` FIFO, so one join
  drains all of them. In
  `testRegistryPublisher_EmitsConsistentSnapshots_DuringRapidMutations` I
  preserved the original test's "last book must appear in a snapshot"
  assertion (previously proven via `.filter{}.first().sink{fulfill()}`) by
  capturing a `lastBookObserved` bool inside the retained `.sink` instead of
  dropping that check.

## KEEP (3 raw hits, 2 files, untouched)

- **`BookCellModelActionTests.swift`** (`testRemove_doesNotShowAlertImmediatelyOrAfterDrain`,
  L237-239): a hand-rolled `DispatchQueue.main.async { drain.fulfill() }` +
  `wait(for:[drain], timeout: 1.0)` — this is already the exact bounded
  main-queue-drain shape (not a wall-clock guess), just not routed through the
  shared `drainMainQueue()` helper. No BookRegistry catalog seam involved
  (BookCellModel, not BookRegistryStore/TPPBookRegistry) and nothing to fix
  per the inviolable rule — left as-is.
- **`ButtonStateMonotonicClampTests.swift`** (`settleThrottle()`, L238-245): a
  `DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { settled.fulfill()
  }` + `wait(for:[settled], timeout: 5.0)`, deliberately scheduled *past* the
  production button-state pipeline's real 50ms `RunLoop.main` `.throttle`
  window. In-file comment already documents this replaced a PRIOR fixed
  `RunLoop.main.run(until: now + 0.12)` wall-clock spin that silently asserted
  stale state under CI load. No catalog seam exists for a Combine `.throttle`
  interval (mock registry, not `BookRegistryStore`), and the current shape is
  already the correct bounded technique for a real fixed-interval timer —
  nothing to convert.

## UNMAPPED (2 raw hits, 2 files)

- **`TPPBookRegistryAtomicWriteTests.testConcurrentSaves_EveryDiskStateBetweenSaves_IsValidJSON`**
  (L305-311) and **`TPPBookRegistryPersistenceTests.testConcurrentSaves_ProduceValidJSONOnDisk`**
  (L424-430): both wait on a `DispatchGroup.notify` covering 20-30 concurrent
  `sync.save(for:)` / `sync?.save(for:)` fire-and-forget calls into
  `BookRegistrySync`'s private `diskWriteQueue`. **No catalog seam exists for
  that queue** — only `BookRegistryStore.syncQueue` has
  `_awaitPendingWritesForTesting()`; `BookRegistrySync`'s disk-write path is a
  different queue entirely. Genuinely bounded by a real
  `DispatchGroup.notify` + (in one case) a background-thread completion —
  not a settle delay — so left byte-for-byte with an inline `UNMAPPED` comment
  citing this transcript's reasoning. Good Wave-3 seam candidate
  (`BookRegistrySync._awaitPendingSaveForTesting()` mirroring S1/S2).

## Verification

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' <file>   # before -> after
TPPBookRegistryAtomicWriteTests.swift    : 2 -> 2   (1 UNMAPPED wait(for:) retained + 1 doc-comment mention)
TPPBookRegistryIntegrationTests.swift    : 10 -> 0
TPPBookRegistryLargeCorpusTests.swift    : 1 -> 1   (doc-comment mention only, 0 functional)
TPPBookRegistryMigrationTests.swift      : 1 -> 1   (doc-comment mention only, 0 functional)
TPPBookRegistryPersistenceTests.swift    : 3 -> 2   (1 UNMAPPED wait(for:) retained + 1 doc-comment mention)
TPPBookRegistryTests.swift               : 1 -> 1   (doc-comment mention only, 0 functional)
BookCellModelStateTests.swift            : 2 -> 0
```

Every "after" hit that isn't the two documented UNMAPPED `wait(for:)` sites is
a doc-comment (`/// Wave-2 ...: replaced the \`wait(for:timeout:...)\` + ...`)
explaining the conversion — confirmed line-by-line, none are live code:

```
$ grep -nE 'wait\(for:|waitForExpectations|fulfillment\(of:' <changed files>
TPPBookRegistryLargeCorpusTests.swift:114:  /// Wave-2 ...: replaced the `wait(for:timeout:)` +
TPPBookRegistryMigrationTests.swift:86:      /// Wave-2 ...: replaced the `wait(for:timeout:30.0)` +
TPPBookRegistryAtomicWriteTests.swift:105:   /// Wave-2 ...: replaced the `wait(for:timeout:30.0)` +
TPPBookRegistryAtomicWriteTests.swift:311:   wait(for: [writeDone, readDone], timeout: 10.0)      <- UNMAPPED, documented
TPPBookRegistryPersistenceTests.swift:100:  /// Wave-2 ...: replaced the `wait(for:timeout:30.0)` +
TPPBookRegistryPersistenceTests.swift:430:  wait(for: [waitExp], timeout: 10.0)                    <- UNMAPPED, documented
TPPBookRegistryTests.swift:533:              // `wait(for:timeout:5.0)` with the S2 seam
```

DELETE-bucket check — must be empty (all `Thread.sleep`/`usleep`/
`asyncAfter…fulfill`/hand-rolled `while Date() < deadline` eliminated):

```
$ grep -nE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' \
    PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift \
    PalaceTests/BookRegistry/TPPBookRegistryIntegrationTests.swift \
    PalaceTests/BookRegistry/TPPBookRegistryLargeCorpusTests.swift \
    PalaceTests/BookRegistry/TPPBookRegistryMigrationTests.swift \
    PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift \
    PalaceTests/BookRegistry/TPPBookRegistryTests.swift \
    PalaceTests/BookStateManagement/BookCellModelStateTests.swift
(empty)
```

No DELETE-bucket occurrences existed in this module to begin with — every
fixed-duration wait found (`RunLoop.current.run(until: Date(timeIntervalSinceNow:
N))`) was a settle-delay riding alongside a genuine async signal, so each was
CONVERTED to a seam join rather than deleted outright (there was always a real
event to join, never a pure decorative sleep).

**Sanity check for silent drops:** 25 (CONVERT) + 3 (KEEP) + 2 (UNMAPPED) = 30
= sum of every file's "Before" column above. No occurrence was silently
dropped.

## Consistency / correctness checks run

- No `await await` / `async async` typos: `grep -rn 'await await\|async async'
  PalaceTests/BookRegistry PalaceTests/BookStateManagement PalaceTests/Sync` →
  empty.
- No function uses `await` without an `async` signature (scripted AST-light
  brace-depth scan across all 7 changed files) → zero mismatches.
- No function marked `async` with zero `await` in its body (same scan) → zero
  dead-async annotations.
- Every touched test class carries `@MainActor` (required — `_awaitPendingWritesForTesting()`
  and `drainMainQueueAsync()` are `@MainActor`-isolated / same-actor-safe):
  confirmed for `TPPBookRegistryAtomicWriteTests`, `TPPBookRegistryLargeCorpusTests`,
  `TPPBookRegistryMigrationTests`, `TPPBookRegistryPersistenceTests`,
  `TPPBookRegistryLoadReentrancyTests`, `TPPBookRegistryPublisherTests`,
  `TPPBookRegistryThreadSafetyTests`, `BookCellModelStateTests`.
- Brace-count diff sanity (`git diff` added-lines `{`/`}` vs removed-lines
  `{`/`}`) balances to zero net across every changed file (one file,
  `TPPBookRegistryPersistenceTests.swift`, has a pre-existing +4 raw-brace
  imbalance from JSON string literals like `"{\"page\": 1}"` — confirmed
  identical in `git show HEAD:...`, i.e. present before this wave's edits too,
  not introduced by them).

```
$ git status --short
 M PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift
 M PalaceTests/BookRegistry/TPPBookRegistryIntegrationTests.swift
 M PalaceTests/BookRegistry/TPPBookRegistryLargeCorpusTests.swift
 M PalaceTests/BookRegistry/TPPBookRegistryMigrationTests.swift
 M PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift
 M PalaceTests/BookRegistry/TPPBookRegistryTests.swift
 M PalaceTests/BookStateManagement/BookCellModelStateTests.swift
```

## Aggregate tally

| Bucket | Count |
|---|---|
| CONVERT | 25 |
| DELETE | 0 |
| KEEP | 3 |
| UNMAPPED | 2 |
| **Total (Before)** | **30** |

No bare unbounded `await` introduced anywhere in this module — every `await`
added targets `BookRegistryStore._awaitPendingWritesForTesting()` (S1),
`TPPBookRegistry._awaitPendingWritesForTesting()` (S2), or the pre-existing
`drainMainQueueAsync()` bounded primitive.

## Off-limits confirmation

- No edits to `Palace/**` (production untouched — `git diff --stat` above only
  lists the 7 test files).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift` (read-only, to
  confirm the `drainMainQueueAsync()` contract before using it).
- No other module's test dir touched — only `PalaceTests/BookRegistry/`,
  `PalaceTests/BookStateManagement/`, `PalaceTests/Sync/` edited (and
  `PalaceTests/Sync/` needed zero changes).
- Not committed, not pushed.
