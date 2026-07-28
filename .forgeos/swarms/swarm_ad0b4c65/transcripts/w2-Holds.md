# Transcript — Wave-2 wall-clock-wait conversion, module Holds (swarm_ad0b4c65)

Worked in worktree `.claude/worktrees/swarm_ad0b4c65-w2-holds`, already on the
wave-1 seam commit (`b4e6ba841`), no new branch created. Scope:
`PalaceTests/Holds/` only.

## Files in scope
- `PalaceTests/Holds/HoldsViewModelTests.swift` — the only file in the
  directory (`ls PalaceTests/Holds/` returns exactly this one file).

## Files changed
**None.** Zero edits made. Every wall-clock-wait occurrence in this file maps
to HoldsViewModel's own notification-driven Combine pipeline, for which the
dispatch explicitly states no S7 seam exists yet — so every occurrence buckets
to UNMAPPED per the bounded-await rule ("when in doubt, KEEP + flag; never
guess"). `git status --short` / `git diff --stat` both empty — confirmed
no changes to the working tree.

## Why every hit is UNMAPPED, not CONVERT

Read `Palace/Holds/HoldsViewModel.swift` (production, read-only) to confirm
the actual pipeline shape before bucketing. It wires four
`NotificationCenter` publishers into the `Store`:

```swift
NotificationCenter.default.publisher(for: .TPPSyncBegan)
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.store.send(.syncBegan) }

syncEnd.merge(with: registryChange)
    .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
    .sink { [weak self] _ in self?.store.send(.syncEnded); self?.reloadData() }

NotificationCenter.default.publisher(for: .TPPSyncFailed)
    .receive(on: DispatchQueue.main)
    .sink { [weak self] n in self?.dispatchSyncFailure(n) }
```

So every test that posts `.TPPSyncBegan` / `.TPPSyncEnded` / `.TPPSyncFailed` /
`.TPPBookRegistryDidChange` and waits on `$isLoading` / `$syncError` /
`$visibleBooks` is waiting on this in-`HoldsViewModel` pipeline (either the
plain `.receive(on: main)` hop or the merged `.debounce(300ms).receive(on:
main)` hop) — exactly the pipeline the dispatch calls out by name as
"not yet built" a seam for. No catalog seam (S1–S11, or any pre-existing
`_await*ForTesting()`) targets `HoldsViewModel` itself. Converting any of
these to a bare `await` would either (a) invent an unbounded await with no
real seam behind it, or (b) require production edits to `HoldsViewModel.swift`,
both explicitly off-limits.

Note: 3 pre-existing `await drainMainQueueAsync()` calls already sit in this
file (lines 647, 671, 708, all against `.TPPSyncFailed` posts) — these are
**not** part of my conversion (they don't match the wait/fulfillment grep,
they were already deterministic on entry) and I left them untouched. I
deliberately did **not** extend that same drain-based pattern to the other
`.TPPSyncFailed`/`.TPPSyncBegan` wait sites below, even though it looks
superficially similar: the dispatch's UNMAPPED instruction for this pipeline
is unqualified ("waits on the HoldsViewModel debounce are UNMAPPED... don't
invent... never guess"), and I'm not the one who validated that drain-based
substitution for the other call sites — flagging for the orchestrator instead
of guessing.

## Bucket tally

| Bucket | Count |
|---|---|
| CONVERT | 0 |
| DELETE | 0 |
| KEEP | 0 |
| UNMAPPED | 15 |

No `Thread.sleep` / `usleep` / `asyncAfter{...fulfill()}` / hand-rolled
`while Date() < deadline` present anywhere in the file (grep below is empty) —
so the DELETE bucket is legitimately zero, not a silent drop.

## UNMAPPED list (all 15 wait/fulfillment occurrences, verbatim, untouched)

| Line | Test | Notification → published property | Pipeline hop |
|---|---|---|---|
| 93 | `testSyncBeganSetsLoadingTrue` | `.TPPSyncBegan` → `$isLoading` | plain `.receive(on: main)` |
| 115 | `testSyncEndedSetsLoadingFalse` | `.TPPSyncEnded` → `$isLoading` | merged `.debounce(300ms)` |
| 318 | `testRegistryDidChange_ReloadsData` | `.TPPBookRegistryDidChange` → `$visibleBooks` | merged `.debounce(300ms)` |
| 406 | `testIsLoading_PublishesChanges` | `.TPPSyncBegan` → `$isLoading` (sync `wait(for:)`, non-`async` test) | plain `.receive(on: main)` |
| 431 | `testVisibleBooks_PublishesChanges` | `.TPPBookRegistryDidChange` → `$visibleBooks` | merged `.debounce(300ms)` |
| 494 | `testSyncFailure_SetsSyncError` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 520 | `testSyncFailure_WithProblemDocument_ShowsServerMessage` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 540 | `testSyncFailure_WithoutProblemDocument_ShowsGenericMessage` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 561 | `testSyncFailure_StopsLoading` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 579 | `testSyncBegan_ClearsPreviousSyncError` (errorSet) | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 591 | `testSyncBegan_ClearsPreviousSyncError` (errorCleared) | `.TPPSyncBegan` → `$syncError` clears | plain `.receive(on: main)` |
| 614 | `testDismissSyncError_ClearsError` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 737 | `testSyncFailure_LibraryNeedsAuth_AndHasCredentials_ShowsBanner` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 761 | `testSyncFailure_AuthenticatedUser_ShowsErrorBanner` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |
| 785 | `testSyncFailure_WithTitleOnly_UsesTitle` | `.TPPSyncFailed` → `$syncError` | plain `.receive(on: main)` |

All 15 recorded here for the orchestrator; none converted, none deleted, none
touched. No bare unbounded `await` was introduced anywhere (none was written
at all, since every hit is UNMAPPED).

## Verification (paste, per playbook)

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Holds/HoldsViewModelTests.swift
15
```
Before → after: 15 → 15 (0 CONVERT + 0 DELETE + 0 KEEP + 15 UNMAPPED = 15,
no silent drop).

```
$ grep -nE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/Holds/HoldsViewModelTests.swift
(empty)
```

Bounded-await proof: N/A — zero `await …ForTesting()` / continuations were
added (0 edits made).

```
$ git status --short
(empty)
$ git diff --stat
(empty)
```

## Off-limits confirmation
- No edits to `Palace/**` (only read `Palace/Holds/HoldsViewModel.swift` and
  `Palace/Holds/HoldsReducer.swift`/`HoldsView.swift` were located but not
  needed/read beyond confirming scope).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No other module's test dir touched.
- Not committed, not pushed.
