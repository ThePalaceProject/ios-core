# Transcript — Wave-2 wall-clock-wait conversion, module Audiobooks (CRITICAL-PATH, swarm_ad0b4c65)

Worked in worktree `.claude/worktrees/swarm_ad0b4c65-w2-audiobooks`, already on
the wave-1 seam commit (`b4e6ba841`), no new branch created. Scope:
`PalaceTests/Audiobook/` and `PalaceTests/Audiobooks/` ONLY (both directories,
including `Audiobook/Vendors/` and `Audiobooks/Mocks/`).

## Files in scope (43 Swift files)

```
PalaceTests/Audiobook/*.swift (17 files)
PalaceTests/Audiobook/Vendors/*.swift (5 files)
PalaceTests/Audiobooks/*.swift (20 files)
PalaceTests/Audiobooks/Mocks/AudiobookEngineMock.swift (1 file)
```

Full listing captured via `find PalaceTests/Audiobook PalaceTests/Audiobooks
-type f -name "*.swift"` — see command history; omitted here for brevity.

## Files changed

**None.** Zero edits made. `git status --short` / `git diff --stat` both
empty. Every wall-clock-wait occurrence in this module's test directories
buckets to either KEEP (direct-synchronous or 3rd-party-vendor-boundary
callback) or UNMAPPED (fire-and-forget async on a class with no catalog
seam) — never CONVERT, never DELETE.

## Search sweep (verification these are the only candidates)

```
$ grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/Audiobook PalaceTests/Audiobooks
(empty)
```

```
$ grep -rn 'DispatchSemaphore\|XCTWaiter\|RunLoop' PalaceTests/Audiobook PalaceTests/Audiobooks
(only hit: AudiobookSessionPresenterTests.swift's `spinRunLoopForPublisherDelivery()`
 helper — already migrated to `drainMainQueue()` per its own comment, no
 RunLoop.main.run(until:) spin remains; nothing to convert)
```

```
$ grep -rn 'Task\.sleep' PalaceTests/Audiobook PalaceTests/Audiobooks
NowPlayingCoordinatorTests.swift:342          (comment only)
NowPlayingCoordinatorBackgroundTests.swift:135 (comment only)
AudiobookOpenStateRaceTests.swift:108          (see KEEP analysis below)
AudiobookFirstOpenHangTests.swift:137,315,344  (see KEEP analysis below)
```

None of the `Task.sleep` hits are wall-clock-settle anti-patterns:
- `AudiobookOpenStateRaceTests.swift:108` — an 80ms sleep used to assert the
  gate is still BLOCKING (negative "hasn't resolved yet" check) before the
  test drives the state transition that unblocks it. Intrinsically
  time-based negative assertion — KEEP bucket 2.
- `AudiobookFirstOpenHangTests.swift` (×3) — each schedules a deliberately
  delayed signal (`gate.markReady()` / `gate.markFailed()`) on a background
  `Task` to exercise `PlaybackReadinessGate`'s real continuation-based
  concurrent-waiter contract. The actual wait under test is
  `try await gate.awaitReady(timeout:)` — native async/await against
  production code, no `XCTestExpectation` involved at all. This is a mock
  delay simulating a real-world race, not a wall-clock substitute for a
  deterministic join — KEEP bucket 3 (injected-delay simulation).

Neither of the above two files match the `wait(for:|waitForExpectations|
fulfillment(of:` grep, so they are outside the primary bucket tally below;
noted here for completeness since the playbook's DELETE bucket explicitly
calls out "Task.sleep-as-delay" and I wanted to show these were reviewed and
are NOT that pattern.

## Primary bucket tally (`wait(for:`/`waitForExpectations`/`fulfillment(of:`)

| File | Hits | Bucket | Why |
|---|---|---|---|
| `Audiobook/AudiobookBookmarkBusinessLogicPositionWriteTests.swift` | 1 (comment only) | N/A | grep hit is prose in a doc-comment ("the prior `wait(for:timeout:)` variant…") describing an *already-completed* migration to `_awaitPositionWriteForTesting()` (seam). Zero live occurrences. |
| `Audiobook/AudiobookLoaderDispatchTests.swift` | 2 | UNMAPPED | waits on `AudiobookLoader.load()` completion |
| `Audiobook/AudiobookLoaderOPDSShapeMatrixTests.swift` | 1 | UNMAPPED | waits on `AudiobookLoader.load()` completion |
| `Audiobook/AudiobookLoaderTests.swift` | 2 | UNMAPPED | waits on `AudiobookLoader.load()` completion |
| `Audiobook/Vendors/AudiobookVendorAdapterTests.swift` | 2 | KEEP | `SpyAdapter.resolveManifest` calls `completion(stubbedResult)` synchronously, inline — direct sync callback |
| `Audiobook/Vendors/BearerTokenAdapterTests.swift` | 4 | KEEP | 3rd-party-boundary adapter (`BearerTokenAdapter.resolveManifest`) |
| `Audiobook/Vendors/LCPAdapterTests.swift` | 5 | KEEP | 3rd-party-boundary adapter (`LCPAdapter.resolveManifest`, LCP SDK) |
| `Audiobook/Vendors/LocalFileAdapterTests.swift` | 4 | KEEP | 3rd-party-boundary adapter (`LocalFileAdapter.resolveManifest`) |
| `Audiobook/Vendors/OpenAccessAdapterTests.swift` | 9 | KEEP | 3rd-party-boundary adapter (`OpenAccessAdapter.resolveManifest`) |
| `Audiobooks/AudiobookLoaderFinalizeBuildTests.swift` | 1 | KEEP | `loader.finalizeBuild(...)` completes synchronously on every branch in `AudiobookLoader.swift` (decode-fail / factory-fail / zero-track / success all call `completion(...)` directly, no `Task`/dispatch hop) — direct sync callback |
| `Audiobooks/AudiobookOpenStateRaceTests.swift` | 1 | KEEP | not a fire-and-forget completion at all — a `Task` wrapping `try await account.awaitReady()`, deliberately exercising a real async blocking gate; the `fulfillment(of:)` just signals the wrapper Task finished after the test transitions state. No catalog seam applies (this isn't the class the seam catalog covers) and it's not a settle-delay — legitimate concurrency-test shape |
| `Audiobooks/AudioEngineWrapperTests.swift` | 2 | KEEP | `AudiobookEngineMock.closeBook(bookId:completion:)` calls `completion()` synchronously (the `deferCloseCompletion=false` path used by both tests) — direct sync callback |
| `Audiobooks/CrossVendorSmokeTests.swift` | 4 | KEEP | same 3rd-party-boundary adapters as above (LCP/BearerToken/OpenAccess/LocalFile), already using `await fulfillment(of:)` |

**Totals:** CONVERT 0, DELETE 0, KEEP 32, UNMAPPED 5 (37 live occurrences + 1
comment-only false-positive grep hit = 38 raw grep count across the 13 files
with any hit — no silent drop).

## Why the `AudiobookLoader.load()` waits are UNMAPPED, not CONVERT

Read `Palace/Audiobooks/AudiobookLoader.swift` (production, read-only). `load()`
resolves via:
```swift
let finish: (Result<...>) -> Void = { [weak self] result in
    Task { @MainActor in
        guard let self else { return }
        if self.isCancelled { completion(.failure(.cancelled)); return }
        completion(result)
    }
}
```
— every terminal completion is wrapped in a fire-and-forget `Task { @MainActor
in ... }` hop, so it is NOT a direct synchronous callback (rules out KEEP
bucket 1). `AudiobookLoader` has no `_await*ForTesting()` seam anywhere in
`Palace/Audiobooks/` (grepped `ForTesting` across `Palace/` — only
`NowPlayingCoordinator._awaitPendingUpdateForTesting()` and
`AudiobookBookmarkBusinessLogic._awaitPositionWriteForTesting()` exist, neither
of which `AudiobookLoader` forwards through). Per the bucket protocol this is
squarely bucket 4 (UNMAPPED): "a fire-and-forget wait whose class has NO
catalog seam. Leave as-is... maybe a Wave-3 seam." I did not invent one.

The existing `wait(for: [exp], timeout: N)` calls (2–10s ceilings) at these 5
sites are left byte-for-byte:
- `AudiobookLoaderDispatchTests.swift:106,302`
- `AudiobookLoaderOPDSShapeMatrixTests.swift:230`
- `AudiobookLoaderTests.swift:37,63`

**Flag for orchestrator:** a Wave-3 seam on `AudiobookLoader` (e.g.
`_awaitLoadForTesting()` mirroring the existing `_awaitPositionWriteForTesting`
/ `_awaitPendingUpdateForTesting` shape) would let all 5 of these convert
cleanly — they're all genuinely waiting on the same single-use fire-and-forget
`Task` hop inside `load()`.

## Why the vendor-adapter waits are KEEP, not CONVERT

Per the dispatch: "the vendor-adapter tests (OpenAccessAdapter/LCPAdapter/
BearerTokenAdapter/LocalFileAdapter) wait on 3rd-party PalaceAudiobookToolkit/
LCP completion handlers — those are KEEP (direct callback) or an IN-TEST
`withCheckedContinuation` resumed from the completion (NO production change).
Do NOT invent a seam for 3rd-party code." All 24 occurrences across
`Vendors/BearerTokenAdapterTests.swift` (4), `Vendors/LCPAdapterTests.swift`
(5), `Vendors/LocalFileAdapterTests.swift` (4), `Vendors/OpenAccessAdapterTests.swift`
(9), and `CrossVendorSmokeTests.swift` (4, already `await fulfillment(of:)`)
match this exactly — they drive the real adapter classes (with
stubbed/mocked network + downloadCenter + file-reader dependencies) across the
LCP/vendor boundary. Given the "cannot build locally, CI-gated" constraint and
the explicit "Conservative" instruction, I left all 24 as-is rather than
rewriting to `withCheckedContinuation` — that rewrite is offered as optional in
the playbook, not required, and is unverifiable without a build. Two more
(`Vendors/AudiobookVendorAdapterTests.swift`, 2 occurrences) use an in-test
`SpyAdapter` whose `resolveManifest` fires `completion(stubbedResult)`
synchronously inline — the cleanest KEEP bucket-1 case (no async hop at all).

## Verification (paste, per playbook)

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' <each file with a hit>
PalaceTests/Audiobook/AudiobookBookmarkBusinessLogicPositionWriteTests.swift:1   (comment, not live)
PalaceTests/Audiobook/AudiobookLoaderDispatchTests.swift:2
PalaceTests/Audiobook/AudiobookLoaderOPDSShapeMatrixTests.swift:1
PalaceTests/Audiobook/AudiobookLoaderTests.swift:2
PalaceTests/Audiobook/Vendors/AudiobookVendorAdapterTests.swift:2
PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift:4
PalaceTests/Audiobook/Vendors/LCPAdapterTests.swift:5
PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift:4
PalaceTests/Audiobook/Vendors/OpenAccessAdapterTests.swift:9
PalaceTests/Audiobooks/AudiobookLoaderFinalizeBuildTests.swift:1
PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift:1
PalaceTests/Audiobooks/AudioEngineWrapperTests.swift:2
PalaceTests/Audiobooks/CrossVendorSmokeTests.swift:4
```
Before → after: identical per file (0 CONVERT, 0 DELETE everywhere) —
1 comment-only + 5 UNMAPPED + 32 KEEP = 38 raw hits, no silent drop.

```
$ grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/Audiobook PalaceTests/Audiobooks
(empty)
```

Bounded-await proof: N/A — zero `await …ForTesting()` calls or continuations
were added (0 edits made; every candidate already resolved to KEEP or
UNMAPPED, never CONVERT).

```
$ git status --short
(empty)
$ git diff --stat
(empty)
```

## Off-limits confirmation
- No edits to `Palace/**` — only read `Palace/Audiobooks/AudiobookLoader.swift`
  (to confirm the Task-hop shape backing the UNMAPPED call) and grepped for
  `ForTesting` seams across `Palace/` (read-only).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No other module's test dir touched (only `PalaceTests/Audiobook/` and
  `PalaceTests/Audiobooks/`, including their `Vendors/`/`Mocks/` subdirs).
- Not committed, not pushed.
