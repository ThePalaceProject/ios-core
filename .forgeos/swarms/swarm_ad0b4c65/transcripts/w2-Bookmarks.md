# Transcript — Wave-2 wall-clock-wait conversion, module Bookmarks (swarm_ad0b4c65)

Worked in worktree `.claude/worktrees/swarm_ad0b4c65-w2-bookmarks`, already on
the wave-1 seam commit (`b4e6ba841`), no new branch created. Scope:
`PalaceTests/Bookmarks/` only.

## Files in scope
`ls PalaceTests/Bookmarks/` returns exactly 3 files:
- `PalaceTests/Bookmarks/TPPAnnotationsTests.swift` (1601 lines)
- `PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift` (195 lines)
- `PalaceTests/Bookmarks/TPPBookmarkSpecTests.swift` (39 lines — zero wait
  occurrences, not discussed further)

## Files changed
**None.** Zero edits made. Every wall-clock-wait occurrence in this module
buckets to **KEEP** — none matches the CONVERT criterion ("fire-and-forget
async whose owning production class has a catalog seam"), and none is a
sleep/poll anti-pattern eligible for DELETE. `git status --short` / `git diff
--stat` both empty — confirmed no changes to the working tree.

Neither of the two seams named in my dispatch (`AudiobookBookmarkBusinessLogic
._awaitPositionWriteForTesting()`, `TPPBookRegistry
._awaitPendingWritesForTesting()`) is referenced anywhere in this directory —
grepped `TPPBookRegistry|AudiobookBookmarkBusinessLogic|BookRegistryStore`
across all 3 files, zero hits. So there was no seam-join to wire up in this
module; the two production classes named as candidates simply aren't the
dependency for anything under test in `PalaceTests/Bookmarks/`.

## Why every hit is KEEP, not CONVERT

Read `Palace/Reader2/Bookmarks/TPPAnnotations.swift` and
`Palace/Reader2/Bookmarks/TPPBookmarkDeletionLog.swift` (production,
read-only) to confirm the actual completion mechanics before bucketing.

**Group A — `TPPBookmarkDeletionLogTests.swift` line 189
(`testThreadSafety_ConcurrentWrites`):** `TPPBookmarkDeletionLog.logDeletion`
is fire-and-forget (`queue.async(flags: .barrier) { ... }`) with no catalog
seam. But the test's `expectation.fulfill()` fires *inside* the
`DispatchQueue.global().async` block right after calling `logDeletion(...)`,
not after the barrier write settles — the test-authored comment (lines
186–188) already documents why this is sound: the follow-up
`pendingDeletions(forBook:)` call does a synchronous `queue.sync` read, and a
concurrent-queue `sync` after a `.barrier` submission is guaranteed to drain
every barrier block submitted before it. So `waitForExpectations` only needs
to wait for all 100 dispatch closures to have been *issued* (a real,
non-arbitrary signal — not a wall-clock guess), and the subsequent
`queue.sync` provides the actual settle guarantee. No seam needed, no
timing assumption made. KEEP, byte-for-byte.

**Group B — `TPPAnnotationsTests.swift`, 15 `waitForExpectations` call sites
(lines 304, 350, 372, 429, 480, 513, 548, 580, 609, 632, 665, 689, 868, 986,
1017) + the `testTPPAnnotations_PostListeningPosition_CallsPostReadingPosition`
site at 1017:** every one of these fulfills the expectation from *inside the
actual completion closure passed to the API under test*
(`TPPAnnotations.postAnnotation` / `.getServerBookmarks` / `.deleteBookmark` /
`.deleteAllBookmarks` / `.postListeningPosition`). The completion parameter
**is** the API's only return channel — there is no side-channel state a seam
could join on instead. `TPPNetworkExecutor._awaitInFlightForTesting()` drains
*all* in-flight network Tasks generically; it cannot hand back the specific
`(success, id, timestamp)` tuple these tests assert on, so it cannot replace
the expectation here even where the executor happens to be the one with a
catalog seam. This is the standard, correct way to test a completion-handler
API — not the wall-clock anti-pattern the wave targets. KEEP, byte-for-byte,
all 15.

**Group C — `TPPAnnotationsTests.swift` lines 1250, 1415
(`TPPAnnotationsHermeticTests.postAndWait` / `testDeleteBookmark_...`):** these
route through `TPPAnnotations.executorOverride = mock` (a
`RecordingExecutorMock`) whose `POST`/`DELETE`/`GET` overrides call
`completion?(...)` **synchronously, in the same call stack** (see
`RecordingExecutorMock.POST`, lines 1156–1163: no dispatch, no Task — direct
invocation). `exp.fulfill()` therefore runs before `wait(for:...)` is ever
reached. This is bucket-3's textbook case: "Expectations fulfilled by a DIRECT
synchronous injected callback (no async hop, no CPU race)." KEEP, byte-for-byte,
both.

**Group D — `TPPAnnotationsTests.swift` line 1116
(`testTPPAnnotations_DeleteBookmarks_HandlesArray`):** `TPPAnnotations
.deleteBookmarks(_:)` is genuinely fire-and-forget (void return, no
completion parameter) and internally goes through `Self.currentExecutor`
(`TPPNetworkExecutor`, which **does** have a catalog seam). I checked whether
`await AppContainer.production().networkExecutor._awaitInFlightForTesting()`
could replace the hand-rolled `DispatchQueue.main.async { drain.fulfill() };
wait(for: [drain], timeout: 1.0)` — but this test class
(`TPPAnnotationsTests`, unlike `TPPAnnotationsHermeticTests`) never installs
`TPPAnnotations.executorOverride`, so `currentExecutor` here resolves to the
live `AppContainer.production().networkExecutor` **shared singleton**. Joining
on that seam from this test would await in-flight work belonging to whatever
else in the process happens to be using the production singleton at the same
moment — a new source of cross-test coupling/nondeterminism this test doesn't
have today, and exactly the kind of guess the playbook says not to make
("When in doubt, KEEP + flag; never guess"). The existing hand-rolled main-queue
drain is already bounded and deterministic (FIFO `DispatchQueue.main.async`,
no fixed delay — mechanically identical to the shared `drainMainQueue()`
helper in `XCTestCase+drainMainQueue.swift`, just not calling it). Flagging for
the orchestrator as a possible Wave-3 candidate (would need
`TPPAnnotationsTests` to also set `executorOverride` to a test-scoped executor
before this seam-join becomes safe) — not converted here. KEEP, byte-for-byte.

## Aside (not fixed, out of scope for this wave)
`TPPAnnotationsTests.setUp()` builds `testNetworkExecutor` (a
`TPPNetworkExecutor` wired to `MockAnnotationsURLProtocol`) but never assigns
it to `TPPAnnotations.executorOverride` — so Group B's 15 tests exercise
whatever `AppContainer.production().networkExecutor` actually does, not the
mock. This is a pre-existing test-quality gap (dead setup / non-hermetic
network path), not a wall-clock-wait — left untouched per scope (my mandate is
wait-pattern conversion, not general test hygiene).

## Bucket tally

| Bucket | Count |
|---|---|
| CONVERT | 0 |
| DELETE | 0 |
| KEEP | 19 |
| UNMAPPED | 0 |

No `Thread.sleep` / `usleep` / `asyncAfter{...fulfill()}` / hand-rolled
`while Date() < deadline` present anywhere in the module (grep below is
empty) — so DELETE is legitimately zero, not a silent drop.

## Full KEEP list (19 occurrences, all verbatim, untouched)

| File | Line | Test | Reason |
|---|---|---|---|
| TPPBookmarkDeletionLogTests.swift | 189 | `testThreadSafety_ConcurrentWrites` | fulfill signals dispatch issuance; `queue.sync` in the next line drains barriers — no seam needed |
| TPPAnnotationsTests.swift | 304 | `testTPPAnnotations_GetServerBookmarks_ReturnsNilWhenSyncNotPermitted` | fulfill is the API's own completion |
| TPPAnnotationsTests.swift | 350 | `testTPPAnnotations_GetServerBookmarks_ReturnsNilForNilBook` | same |
| TPPAnnotationsTests.swift | 372 | `testTPPAnnotations_GetServerBookmarks_ReturnsNilForNilURL` | same |
| TPPAnnotationsTests.swift | 429 | `testTPPAnnotations_PostAnnotation_CreatesCorrectRequestFormat` | same |
| TPPAnnotationsTests.swift | 480 | `testTPPAnnotations_PostAnnotation_HandlesSuccessResponse` | same |
| TPPAnnotationsTests.swift | 513 | `testTPPAnnotations_PostAnnotation_HandlesNetworkError` | same |
| TPPAnnotationsTests.swift | 548 | `testTPPAnnotations_PostAnnotation_HandlesNon200StatusCode` | same |
| TPPAnnotationsTests.swift | 580 | `testTPPAnnotations_DeleteBookmark_HandlesSuccessfulDeletion` | same |
| TPPAnnotationsTests.swift | 609 | `testTPPAnnotations_DeleteBookmark_Handles404AsSuccess` | same |
| TPPAnnotationsTests.swift | 632 | `testTPPAnnotations_DeleteBookmark_ReturnsFalseForInvalidURL` | same |
| TPPAnnotationsTests.swift | 665 | `testTPPAnnotations_DeleteBookmark_HandlesServerError` | same |
| TPPAnnotationsTests.swift | 689 | `testTPPAnnotations_DeleteAllBookmarks_CompletesImmediately` | same (also asserts immediacy, not a delay) |
| TPPAnnotationsTests.swift | 868 | `testTPPAnnotations_PostAnnotation_HandlesInvalidJSONGracefully` | same |
| TPPAnnotationsTests.swift | 986 | `testTPPAnnotations_HandlesConcurrentRequests` | same, 5-way fulfillment count matches 5 real completions |
| TPPAnnotationsTests.swift | 1017 | `testTPPAnnotations_PostListeningPosition_CallsPostReadingPosition` | same |
| TPPAnnotationsTests.swift | 1116 | `testTPPAnnotations_DeleteBookmarks_HandlesArray` | bounded FIFO main-queue drain; seam-join would tie to shared `AppContainer.production()` executor — flagged, not converted |
| TPPAnnotationsTests.swift | 1250 | `TPPAnnotationsHermeticTests.postAndWait` (helper used by 12 tests) | `RecordingExecutorMock` invokes completion synchronously — direct callback |
| TPPAnnotationsTests.swift | 1415 | `testDeleteBookmark_InvalidURLString_ReturnsFalseWithoutNetwork` | same synchronous-mock pattern |

All 19 recorded here; none converted, none deleted. No bare unbounded `await`
was introduced anywhere (none was written at all, since every hit is KEEP).

## Verification (paste, per playbook)

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Bookmarks/TPPAnnotationsTests.swift
18
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift
2
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Bookmarks/TPPBookmarkSpecTests.swift
0
```
Before → after: 18 → 18, 2 → 2 (one is a comment mentioning the word at line
188, not a real call — 1 genuine occurrence at line 189), 0 → 0. Remainder in
each file equals KEEP (19 real occurrences total across the module: 18 in
TPPAnnotationsTests.swift + 1 in TPPBookmarkDeletionLogTests.swift); 0 CONVERT
+ 0 DELETE + 0 UNMAPPED — no silent drop.

```
$ grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/Bookmarks/
(empty)
```

Bounded-await proof: N/A — zero `await …ForTesting()` / continuations were
added (0 edits made; every occurrence in this module was already either a
direct/synchronous callback or a real completion-handler signal with no
qualifying catalog seam to join instead).

```
$ git status --short
(empty)
$ git diff --stat
(empty)
```

## Off-limits confirmation
- No edits to `Palace/**` (read `TPPAnnotations.swift` and
  `TPPBookmarkDeletionLog.swift` only, to confirm completion mechanics before
  bucketing — no writes).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No other module's test dir touched.
- Not committed, not pushed.
