# Transcript — Wave-2 wall-clock-wait conversion, module Book (swarm_ad0b4c65)

CRITICAL-PATH module (borrow/registry state). Worked in worktree
`.claude/worktrees/swarm_ad0b4c65-w2-book`, already on the wave-1 seam commit
(`b4e6ba841`), no new branch created. Scope: `PalaceTests/Book/` only.
Cannot build locally (CI-gated) — grep-verified only, evidence pasted below.

## First pass

```
$ grep -rlE 'wait\(for:|waitForExpectations|fulfillment\(of:|awaitCondition|Thread\.sleep|asyncAfter|Task\.sleep|usleep' PalaceTests/Book/
```

over all 23 files in the directory. **9 files matched.** The other 14 files
(`BookAvailabilityFormatterTests`, `BookButtonMapperTests`,
`BookButtonTypeMetaTests`, `BookButtonTypeTests`, `HostFailureTrackerTests`,
`RegistryFileRecoveryTests`, `TPPBookAuthorTests`, `TPPBookButtonsStateTests`,
`TPPBookContentTypeConverterTests`, `TPPBookContentTypeTests`,
`TPPBookDRMProtectedTests`, `TPPBookExtensionsTests`, `TPPBookLocationTests`,
`TPPBookSerializationTests`, `TPPBookTests`) have **zero** wall-clock-wait
patterns — pure value/model tests, no async surface at all.

## Files changed

**2 files, both CONVERTED (S1 seam adopted), nothing else touched.**

- `PalaceTests/Book/BookRegistryStoreTests.swift`
- `PalaceTests/Book/BookRegistrySyncTests.swift`

`git status --short` / `git diff --stat` for these two only; every other
matched file was reviewed and left byte-for-byte (reasons below).

```
$ git diff --stat
 PalaceTests/Book/BookRegistryStoreTests.swift | 334 ++++++++++++--------------
 PalaceTests/Book/BookRegistrySyncTests.swift  |  71 +++---
 2 files changed, 191 insertions(+), 214 deletions(-)
```

## Per-file before → after wait counts

| File | Before (functional) | After (functional) | CONVERT | KEPT | UNMAPPED |
|---|---|---|---|---|---|
| `BookRegistryStoreTests.swift` | 25 | 3 | 22 | 3 | 0 |
| `BookRegistrySyncTests.swift` | 19 | 15 | 4 | 1 | 14 |
| `BookRegistrySyncReentrancyTests.swift` | 5 | 5 | 0 | 5 | 0 |
| `BookRegistrySyncReadinessTests.swift` | 2 | 2 | 0 | 2 | 0 |
| `BookRegistrySyncSideloadExemptionTests.swift` | 2 | 2 | 0 | 0 | 2 |
| `TPPBookRegistryAsyncReadinessTests.swift` | 1 | 1 | 0 | 1 | 0 |
| `BookServiceAudiobookOpenTests.swift` | 2 | 2 | 0 | 2 | 0 |
| `BookmarkManagerTests.swift` | 4 | 4 | 0 | 0 | 4 |
| `BookDetailViewModelTests.swift` | 15 | 15 | 0 | 0 | 15 |

Every row satisfies `Before = CONVERT + KEPT + UNMAPPED` and
`After = KEPT + UNMAPPED` (CONVERTED sites vanish from the raw grep entirely —
the seam join is a plain `await`, not a `wait(for:)`/`fulfillment(of:)`, so it
doesn't reappear as a different match). E.g. `BookRegistrySyncTests.swift`:
19 = 4 + 1 + 14, and after = 1 + 14 = 15 — matching the literal 16-raw-hits
(minus 1 comment) grep below.

## Bounded-await citations (every seam join added)

All 26 converted `await` sites (22 in `BookRegistryStoreTests.swift` + 4 in
`BookRegistrySyncTests.swift`) target exactly one seam:

```swift
await store._awaitPendingWritesForTesting()
```

— `BookRegistryStore._awaitPendingWritesForTesting()` (Palace/Book/Models/BookRegistryStore.swift:110-114),
the wave-1 S1 seam. Bounded by construction: it submits one more `.barrier`
block to `syncQueue` and resumes a `CheckedContinuation` from inside it — since
`syncQueue.async(flags: .barrier)` is FIFO-after-every-prior-barrier-block, the
continuation can only resume once every previously-enqueued `addBook` /
`setState` / `removeBook` / `updateAndRemoveBook` / `removeAll` barrier block
(and its `onComplete`) has finished. No sleep, no poll, no new retained state,
production never calls it — mirrors the pre-existing
`TokenRefreshInterceptor._awaitAuthDispatchForTesting()` shape cited in the
catalog.

One converted site (`test_registrySubject_emitsOnAdd`) additionally uses:

```swift
await drainMainQueueAsync()
```

after the seam join — the playbook explicitly allows this composite ("you MAY
use `await drainMainQueueAsync()` to flush a single main-hop after a seam
join"). Needed because `BookRegistryStore.registry`'s `didSet` re-publishes
`registrySubject` via a nested `DispatchQueue.main.async`, which the syncQueue
barrier alone doesn't wait through; `drainMainQueueAsync()` is FIFO on the main
queue so it can only fire after that already-enqueued publish.

**No bare unbounded `await` was introduced anywhere.** Every `await` added is
either the S1 seam or the pre-existing `drainMainQueueAsync()` bounded
primitive from `XCTestCase+drainMainQueue.swift` (read-only, not edited).

## `BookRegistryStoreTests.swift` — 22 CONVERTED, 3 KEPT

All 22 tests whose entire wait surface was a `BookRegistryStore.addBook` /
`.setState` / `.removeBook` / `.updateAndRemoveBook` completion callback were
rewritten: the completion + `XCTestExpectation` + `wait(for:)` triplet was
replaced with a plain call (no completion) + `await
store._awaitPendingWritesForTesting()`, then direct synchronous assertions
(`store.book(forIdentifier:)`, `store.state(for:)`, etc. — all
`performSync`-backed reads, no further hop needed once the barrier is
drained). Test methods were marked `async` accordingly. Two tests
(`test_removeBook_removesFromRegistry`, `test_updateAndRemoveBook_...`,
`test_removeBook_nonexistentId_...`) kept their `onComplete` closures (they
carry data — the removed book / merged snapshot — that has no other read
path) but joined them via the seam instead of an expectation.

KEPT (3, byte-for-byte, not touched):
- `test_setProcessing_true_thenFalse` (2 waits) — `expectation(forNotification:
  .TPPBookProcessingDidChange)` asserts the actual NotificationCenter payload
  (`bookProcessingBookIDKey` / `bookProcessingValueKey`), not just registry-write
  convergence. `_awaitPendingWritesForTesting()` only proves the post was
  *submitted* (it's nested inside the barrier via a further
  `DispatchQueue.main.async`), not that it was *delivered* with the right
  userInfo. No catalog seam asserts notification-payload content, so converting
  would silently drop UI-badge-relevant coverage. Left as-is with an inline
  rationale comment.
- `test_concurrentReadsAndWrites_noDataRace` (1 wait) — deliberately drives the
  store from raw `DispatchQueue.global()` work items to stress-test the store's
  OWN synchronization under real concurrency; routing through the seam would
  defeat the point. Bounded by `DispatchGroup.notify` (deterministic zero-count
  callback), not a wall-clock poll — nothing to fix.

## `BookRegistrySyncTests.swift` — 4 CONVERTED, 1 KEPT, 14 UNMAPPED

CONVERTED (4): `test_reset_clearsSyncUrlAndStore`,
`test_registrySnapshot_producesSerializableData`,
`test_storeSnapshotWithMultipleStates`,
`test_validateDownloadedContent_marksDownloadNeededWhenFileMissing` — each had
ONLY a `BookRegistryStore.addBook` completion+wait (no other wait in the same
test method), so was safe to make `async` and join via
`store._awaitPendingWritesForTesting()`. `test_reset_clearsSyncUrlAndStore`
additionally joins the seam a second time after `syncManager.reset(...)` since
`reset()` itself calls `store.removeAll()` (another barrier write) before the
`syncUrl`/`allBooks.isEmpty` assertions.

KEPT (1): `awaitRegistrySaved` helper (L886, `wait(for: [saved],
timeout:)`) — joins a real `NotificationCenter.default.addObserver(forName:
.TPPBookRegistryDidChange)` registered BEFORE the save runs; genuinely
deterministic (not a poll), and it's `BookRegistrySync.save`'s own disk-write
completion signal, which S1 (a `BookRegistryStore` seam) cannot observe anyway
— they're different classes.

UNMAPPED (14) — every one is a fire-and-forget wait whose owning class
(`BookRegistrySync`) has **no catalog seam** (only `BookRegistryStore` /
`TPPBookRegistry` / `TPPNetworkExecutor` / `MyBooksDownloadCenter` are
enumerated), so per the inviolable rule nothing was invented:
- **9× `syncManager.load(account:completion:)` / `.sync(currentState:setState:completion:)`
  waits** (L363, 380, 545, 751, 780, 819, 998, 1018, 1042, 1081 — 10 actually,
  see grep below) — `load`/`sync` dispatch their completion via
  `DispatchQueue.main.async` / an internal `Task`, with no
  `_awaitLoadForTesting`/`_awaitSyncForTesting` seam in this wave's catalog.
  Flagged as a good Wave-3 seam candidate.
- **1× `DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill()
  }` → `wait(for:[exp], timeout: 2.0)`** (L506-507,
  `test_sync_whenAlreadySyncing_returnsBeforeSettingSyncingState`) — this is
  structurally the DELETE-bucket shape ("asyncAfter used purely as a settle
  delay"), but it exists specifically to let a *defensive* async Task settle
  before asserting NO state was ever emitted (an absence check with no
  positive edge to join, and no seam exists for "did BookRegistrySync's
  internal re-entrancy Task run"). Converting to a bare `await` without a real
  join target would violate the bounded-await rule; left as-is per the
  dispatch's explicit critical-path caution ("if a wait doesn't cleanly map to
  a catalog seam, mark it UNMAPPED and leave it — do NOT invent an unbounded
  await").
- **3× addBook-completion waits blocked by a co-occurring non-seam wait in the
  same test method** — `snapshotWithOneBook` helper (L846, used by 3 corrupt-
  load/backup tests), `testNonEmptySave_isNeverBlocked...` (L965, followed by
  `awaitRegistrySaved` in the same method), `testSave_writesSchemaVersionField`
  (L1058, ditto). Each of these WOULD be a clean S1 CONVERT in isolation, but
  the same test method also calls `syncManager.load(...)` or
  `awaitRegistrySaved` — both dispatch their completion via
  `DispatchQueue.main.async` with no seam. Making the test method `async` to
  join the addBook half via the seam would force every other `wait(for:)` in
  that same method to run as a **synchronous, thread-blocking wait from inside
  an async `@MainActor` test** — exactly the deadlock hazard
  `XCTestCase+drainMainQueue.swift`'s own doc-comment warns about for
  `drainMainQueue()` ("blocks the executor the `.main.async` block is waiting
  to run on — deadlock under `@MainActor async` tests"). Confirmed this risk is
  real (not hypothetical) by checking `BookRegistrySync.load`/`.save` — both do
  route their completion/notification through `DispatchQueue.main.async`.
  Left byte-for-byte; a real fix needs a `BookRegistrySync`-level seam (Wave-3),
  not a partial per-line conversion.

## `BookRegistrySyncReentrancyTests.swift` — 5 KEPT

All 5 waits (`wait(for:[done], timeout: 5-10s)`) drive
`DispatchQueue.global()`/`DispatchQueue.concurrentPerform` reentrancy/deadlock
regression tests for the Crashlytics 8afb1c66 `saveSync` hang — real concurrent
stress with `DispatchGroup`/`expectedFulfillmentCount` completion signals
(deterministic, not a poll). Converting through a seam would defeat the
purpose (these tests exist specifically to exercise raw-thread concurrency
against the store's own barrier machinery). One site (L178) already carries an
explicit prior-review comment (`FLAKE-003-OK`) confirming this was
deliberately kept generous, not a bug.

## `BookRegistrySyncReadinessTests.swift` / `TPPBookRegistryAsyncReadinessTests.swift` — 3 KEPT

Both files test `Account.awaitReady()`'s gate contract (Accounts-domain, not a
Book-module seam) via a `Task.yield()`-loop + `await fulfillment(of:)` —
already the exact "no wall-clock nap" fix the swarm exists to produce, done in
a prior swarm (comments cite it explicitly: "A bounded `Task.yield()` loop
replaces the old fixed 50ms `Task.sleep`"). Nothing left to convert.

## `BookServiceAudiobookOpenTests.swift` — 2 KEPT

Both `await fulfillment(of: [finished], timeout: 3)` sites join
`BookService.open`'s own `onFinish` completion (no catalog seam for
`BookService`/`AudiobookSessionManaging`) — already documented as deliberate,
deterministic completion joins. The one `Task.sleep` in this file (L185) is
INSIDE the test's own mock (`HookRecordingSession.openAudiobook`), simulating a
download hold — the playbook's explicit KEEP category ("mock schedulers /
injected-clock/delay simulations — the mock's contract"), not a test-side
wait.

## `BookmarkManagerTests.swift` — 4 UNMAPPED

All 4 (`addBookToStore` helper × 1 call-site pattern used by ~20 tests, plus 3
inline `store.addBook(...) { }.fulfill()` sites) are, in isolation, clean S1
CONVERT candidates. But every one of them is immediately followed by
`waitForBarrier()`, this file's own shared helper
(`_ = store.readRegistry { _ in }; drainMainQueue()`), called repeatedly
throughout essentially every test in the file (its own doc-comment explains it
replaced a real flake, `test_everyMutationCallsSave` seeing 4/5 saves). Making
any of these tests `async` to adopt the S1 seam would leave every subsequent
`waitForBarrier()` call in that same method calling synchronous
`drainMainQueue()` from inside an async `@MainActor` test — the same
documented deadlock hazard flagged above for `BookRegistrySyncTests.swift`.
Fixing this properly means converting `waitForBarrier()` itself to an
async-safe `_awaitPendingWritesForTesting()` + `drainMainQueueAsync()` variant
and threading `async` through ~20 call sites file-wide — out of this wave's
per-file remit and too invasive to do safely without broader review. Left
byte-for-byte; flagged as the single best Wave-3 candidate in this module
(one helper rewrite unlocks ~20 tests at once).

## `BookDetailViewModelTests.swift` — 15 UNMAPPED

Every wait in this file joins a Combine `.filter{}.first().sink{}` on
`BookDetailViewModel`'s own `@Published` properties (`$book`, `$bookState`,
`$stableButtonState`, `$isBorrowProcessing`, `$downloadProgress`) driven by
`TPPBookRegistryMock` (a hand-rolled test double per CLAUDE.md's "never hit
real singletons" rule — NOT the real `BookRegistryStore`/`TPPBookRegistry`, so
the S1/S2 seams do not apply to it at all). No catalog seam exists for
`BookDetailViewModel`'s derived publishers either. Every site is already a
deterministic, non-polling Combine join (several with detailed in-file
comments explaining a PRIOR fix from a fixed `asyncAfter`/poll to this exact
pattern, e.g. `testBookState_SetReturning_...` L1038-1052). Nothing to
convert, nothing to delete — left entirely as-is.

## `BookRegistrySyncSideloadExemptionTests.swift` — 2 UNMAPPED

`seedStore` helper's `store.addBook(...)` wait (L137) and `runSync` helper's
`syncManager.sync(...)` wait (L203) are called back-to-back from the same test
methods — same mixed sync/async-hazard reasoning as above (no
`BookRegistrySync` seam for `.sync`, and converting only the `addBook` half
would force the method `async`, endangering the co-located `.sync` wait). Left
as-is.

## Verification (per playbook)

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Book/BookRegistryStoreTests.swift
4   # 3 functional (L285, L296, L452) + 1 in-comment mention (L76, "wait(for:)" in prose)

$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Book/BookRegistrySyncTests.swift
16  # 15 functional + 1 in-comment mention (L869, "`wait(for:)`" in prose)
```

Remainder after CONVERT = KEPT + UNMAPPED in both files, no silent drop:
- `BookRegistryStoreTests.swift`: 25 before → 3 functional after = 22 CONVERTED; 3 = KEPT (3) + UNMAPPED (0). ✓
- `BookRegistrySyncTests.swift`: 19 functional before (20 raw hits − 1 comment)
  → 15 functional after (16 raw hits − 1 comment) = 4 CONVERTED; remaining
  15 = KEPT (1) + UNMAPPED (14). ✓

```
$ grep -nE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' \
    PalaceTests/Book/BookRegistryStoreTests.swift PalaceTests/Book/BookRegistrySyncTests.swift
PalaceTests/Book/BookRegistrySyncTests.swift:506:        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
```

One hit — the documented, deliberately-kept UNMAPPED settle (see above); not a
silent miss, individually justified in-file and in this transcript. Zero
`Thread.sleep`/`usleep`/hand-rolled `while Date() < deadline` anywhere in
either changed file.

```
$ grep -rnE 'Thread\.sleep|usleep|while.*Date\(\).*<' PalaceTests/Book/
(empty — zero hits across the entire module)
```

**No bare unbounded `await` exists anywhere in this module.** Every `await`
added targets `BookRegistryStore._awaitPendingWritesForTesting()` (cited
above) or the pre-existing `drainMainQueueAsync()` primitive.

```
$ git status --short
 M PalaceTests/Book/BookRegistryStoreTests.swift
 M PalaceTests/Book/BookRegistrySyncTests.swift
```

## Aggregate tally (9 files with any wait pattern; 14 files had none)

| Bucket | Count |
|---|---|
| CONVERT | 26 (22 + 4) |
| DELETE | 0 |
| KEEP | 14 (3 + 1 + 5 + 2 + 1 + 2 across the 9 files — see per-file table) |
| UNMAPPED | 35 (14 + 2 + 4 + 15) |

Sanity: 26 + 14 + 35 = 75 = the sum of every file's "Before" column above
(25+19+5+2+2+1+2+4+15). No occurrence was silently dropped.

## Off-limits confirmation
- No edits to `Palace/**` (production untouched — grep confirms
  `git diff --stat` only shows the 2 test files above).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift` (read-only, to
  confirm the `drainMainQueueAsync()` contract before using it).
- No other module's test dir touched — only `PalaceTests/Book/` edited.
- Not committed, not pushed.
