# Wave 4 — PP-4161 streaming-HTML hotfix (Path X)

**Scope:** Maurice-green-lit Path X for swarm `swarm_c2b95c85`. Third
escalation on the Module C-derived streaming-HTML borrow regression.

## 1. Summary

- **REVERTED** the Wave 3 v2.2 `.get/.download/.retry` streamingHTML
  special-case in `BookDetailViewModel.handleAction(...)` and
  `BookCellModel.callDelegate(for:)`. Streaming-HTML books once again flow
  through `didSelectDownload` like every other content type.
- **ADDED** a single early-return in `DownloadStartDispatcher
  .processDownloadWithCredentials(for:withState:andRequest:capturedAccountId:)`
  that short-circuits for `book.defaultBookContentType == .streamingHTML`.
  The dispatcher does NOT call `startBorrow` (no borrow link), does NOT
  call `addDownloadTask` (no decodable asset), and does NOT enter the SAML
  handler. The registry is left in the `.downloadNeeded` state that
  `processUnregisteredState` already seeded via its open-access branch.
- **REPLACED** the v2.2 routing-spy tests with 4 new dispatcher tests
  that pin the early-return contract (streamingHTML at `.downloadNeeded`
  and `.unregistered` both return early; EPUB books still route to
  `startBorrow`; `processUnregisteredState` still seeds `.downloadNeeded`
  for streamingHTML open-access books).

## 2. Files

Production:

```
 Palace/Book/UI/BookDetail/BookDetailViewModel.swift   |  -17 +5  net  -12
 Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift   |  -14 +6  net  -8
 Palace/MyBooks/DownloadStartDispatcher.swift          |  +12 (Path X early-return)
```

Tests:

```
 PalaceTests/Book/BookDetailViewModelTests.swift       |  -141 (v2.2 SpyStartDownloadCenter + 2 tests removed)
 PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift  |  -87  (v2.2 CellSpyStartDownloadCenter + 2 tests removed)
 PalaceTests/MyBooks/DownloadStartDispatcherTests.swift |  +170 (4 new dispatcher tests + streamingHTMLBook helper)
```

`git diff --stat` (Path-X-relevant files only):

```
 Palace/Book/UI/BookDetail/BookDetailViewModel.swift     |  53 +++ (v2.1 .readStreaming arm + presentStreamingReader survive)
 Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift     |  36 ++  (v2.1 .readStreaming offline/loading + .streamingHTML didSelectRead survive)
 Palace/MyBooks/DownloadStartDispatcher.swift            |  12 ++  (Path X)
 PalaceTests/Book/BookDetailViewModelTests.swift         | 142 +++ (v2.1 tests survive, v2.2 removed)
 PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift |  87 --  (v2.2 only; this file's v2.1 tests still here, net -87 from the v2.2 additions removed by Wave 4)
 PalaceTests/MyBooks/DownloadStartDispatcherTests.swift  | 170 +++ (new Wave 4 tests)
```

The net delta of v2.2-only artifacts is exactly the revert; the v2.1
streaming-reader work (NavigationCoordinator route, StreamingReaderView,
BookButtonState mapping) is untouched.

## 3. Tests

New (in `PalaceTests/MyBooks/DownloadStartDispatcherTests.swift`):

- `testProcessDownloadWithCredentials_streamingHTMLBook_returnsEarlyWithoutCallingStartBorrow`
  Asserts no `startBorrow`, no `addDownloadTask`, no SAML handler, no
  Wi-Fi failure for a streamingHTML book at `.downloadNeeded`.
- `testProcessDownloadWithCredentials_streamingHTMLBook_unregisteredState_alsoReturnsEarly`
  Same path with `.unregistered` state — confirms the early-return fires
  BEFORE the borrow-routing arm.
- `testProcessDownloadWithCredentials_epubBook_stillCallsStartBorrow`
  Regression net — EPUB books at `.unregistered` still route to
  `startBorrow` exactly once.
- `testProcessUnregisteredState_streamingHTMLOpenAccessBook_transitionsToDownloadNeeded`
  Confirms `processUnregisteredState`'s open-access branch is
  content-type-agnostic (streamingHTML → `.downloadNeeded`).

Removed (v2.2 routing-spy tests + spy subclasses):

- `PalaceTests/Book/BookDetailViewModelTests.swift`:
  - `testBookDetailViewModel_handleAction_getForStreamingHTMLBook_routesViaBorrowAsyncNotDownload`
  - `testBookDetailViewModel_handleAction_getForEpubBook_stillRoutesViaDownloadCenter`
  - `private final class SpyStartDownloadCenter` (file-private spy)
- `PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift`:
  - `testBookCellModel_callDelegateGet_streamingHTMLBook_routesViaBorrowAsyncNotDownload`
  - `testBookCellModel_callDelegateGet_epubBook_stillRoutesViaDownloadCenter`
  - `private final class CellSpyStartDownloadCenter` (file-private spy)

v2.1 streaming-reader tests retained (untouched by Wave 4):
`testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming`,
`testBookDetailViewModel_didSelectGet_streamingHTMLBook_thenButtonsAreReadStreaming`,
`testBookCellModel_didSelectRead_streamingHTMLBook_presentsStreamingReaderView_viaCoordinator`,
`testBookCellModel_didSelectRead_epubBook_doesNotPushStreamingRoute`.

## 4. BorrowOperation:453 guard status

**Reachability trace under Path X:**

`BorrowOperation.borrowAsync` is called from:
1. `BookDetailViewModel.didSelectReserve` → `downloadCenter.borrowAsync(...)`
2. `BookCellModel.didSelectReserve` → `downloadCenter.borrowAsync(...)`
3. `DownloadStartCoordinator.startBorrow` → `delegate.borrowAsync(...)`

For a streaming-HTML book:

- Paths 1 & 2 are **unreachable** because `BookButtonState.downloadNeeded`
  (and every other state) never produces a `.reserve` button for
  `defaultBookContentType == .streamingHTML`. The button arm yields
  `[.readStreaming, .return]` directly; there's no `.reserve` tap to
  initiate the path.
- Path 3 is **unreachable** because Path X's early-return at
  `DownloadStartDispatcher.processDownloadWithCredentials` short-circuits
  BEFORE the `state == .unregistered || state == .holding` branch that
  would invoke `delegate.startBorrow → DownloadStartCoordinator.startBorrow`.

Conclusion: the `!borrowedBook.isStreamingHTML` clause at
`BorrowOperation.swift:454` is **dead code on the happy path** — no
production caller can route a streaming-HTML book into `borrowAsync`.

**Recommendation: KEEP the guard as defense-in-depth.** Two reasons:
1. Registry-recovery sync paths (e.g. sign-back-in after eviction) may
   in the future call `borrowAsync` directly on books carried over from
   a prior session, bypassing the dispatcher entirely.
2. The guard cost is one operand on a conjunction — keeping it documents
   the invariant ("we never auto-chain a download for streaming-HTML")
   even if today's call graph makes the invariant vacuously true.

The `BorrowOperationStreamingHTMLTests` test class (added in v2.1, still
green) exercises the guard directly with a synthetic streamingHTML book,
so the guard remains test-covered even if unreachable from production.

## 5. Gaps

- **Path X depends on `processUnregisteredState` already seeding
  `.downloadNeeded` for open-access streamingHTML books.** That seeding
  branch is content-type-agnostic by design (it only checks `borrow link
  == nil` + `openAccess != nil`). If a future refactor adds a
  content-type filter to that branch, the dispatcher's early-return
  would still suppress the download but the registry would never
  transition to `.downloadNeeded` → the cell would stay on `.get` and
  the patron could never reach `[.readStreaming, .return]`. The new
  test `testProcessUnregisteredState_streamingHTMLOpenAccessBook_transitionsToDownloadNeeded`
  pins this invariant.
- **No simdrive flow update.** The `.simdrive/journeys/PP-4161-streaming-html-reader.yaml`
  recorded by Wave 1 still asserts the post-v2.2 borrow-then-read shape.
  After Path X, the on-screen behavior should be identical (a single
  tap on Get transitions to the `[.readStreaming, .return]` set), but
  the route through production code is different. The journey may need
  a re-record on green CI; left for the integrator as a follow-up.
- **The `BookCellModelStreamingHTMLTests` file is now staged-new with
  only the v2.1 tests** (the v2.2 additions removed by Wave 4). The
  file's purpose remains clear; no rename needed.

## 6. Definition-of-done evidence

### Check 1 — SUT instantiation

```
$ grep -c "DownloadStartDispatcher(" PalaceTests/MyBooks/DownloadStartDispatcherTests.swift
2
$ grep -c "BookCellModel("           PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift
1
$ grep -c "BookDetailViewModel("      PalaceTests/Book/BookDetailViewModelTests.swift
13
```

```
$ python3 scripts/check-test-name-vs-body.py \
    PalaceTests/MyBooks/DownloadStartDispatcherTests.swift \
    PalaceTests/Book/BookDetailViewModelTests.swift \
    PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift
OK: 3 file(s) checked, 0 fake-wiring tests found.
EXIT: 0
```

### Check 2 — Function-result usage

The Path X production diff in `DownloadStartDispatcher` does not call any
new functions; it inserts a single early-return on an existing predicate
(`book.defaultBookContentType == .streamingHTML`). No discarded results.

The reverts in `BookDetailViewModel` / `BookCellModel` remove calls
(`didSelectReserve`, `didSelectReadStreaming`); they do not introduce
new ones.

### Check 3 — Multi-step test body

None of the new test names contain `across`, `twice`, `reset`, `retry`,
`again`, `roundtrip`, `inProduction`, or `viaX`. The existing v2.1 test
`testBookDetailViewModel_didSelectGet_streamingHTMLBook_thenButtonsAreReadStreaming`
is two-step (assert content-type-then-buttons) and the body asserts both
halves explicitly (per its existing comment).

### Check 4 — Scope coverage

All items from the Wave 4 task scope landed:

| Item | Status |
|------|--------|
| Revert v2.2 special-case in BookDetailViewModel `.get/.download/.retry` | DONE |
| Revert v2.2 special-case in BookCellModel `.get/.download/.retry` | DONE |
| Add streamingHTML early-return in DownloadStartDispatcher.processDownloadWithCredentials | DONE |
| Revert v2.2 tests in BookDetailViewModelTests | DONE (2 tests + spy class removed) |
| Revert v2.2 tests in BookCellModelStreamingHTMLTests | DONE (2 tests + spy class removed) |
| Add 3+ new dispatcher tests | DONE (4 tests) |
| BorrowOperation:453 guard analysis | DONE (section 4 above) |

### Check 5 — Mutation pass (MANDATORY for critical path)

Critical-path file: `Palace/MyBooks/DownloadStartDispatcher.swift`.

Whole-file mutation run (`--diff-only` reports 0 changed lines because
the script's `git diff <base>..HEAD` excludes uncommitted changes;
whole-file is the available proxy and the harder bar):

```
$ HARNESS_SESSION_SIM_UDID=141BD227-6E9A-4409-8D99-2D4FE818238D \
    python3 scripts/palace_mutate.py \
      --file Palace/MyBooks/DownloadStartDispatcher.swift \
      --tests PalaceTests/DownloadStartDispatcherTests --quiet
============================================================
palace-mutate complete
  killed:   13
  survived: 7
  errored:  0
  kill rate: 65.0%
============================================================
```

Threshold ≥ 50% — PASS. 65.0% whole-file.

**Per-line breakdown of mutants on Wave-4-added lines (L192–L207):**

```
KILLED L202: '==' -> '!='   # if book.defaultBookContentType == .streamingHTML
KILLED L205: '||' -> '&&'   # state == .unregistered || state == .holding (existing line, exercised by my fixture)
KILLED L205: '==' -> '!='   # state == .unregistered (existing line)
```

100% kill rate on the lines Path X added or controls. All 7 surviving
mutants are on pre-existing untouched code:

```
SURVIVED L210: '==' -> '!='  (Overdrive distributor check, FEATURE_OVERDRIVE)
SURVIVED L267: '&&'/!=' mutants on the auto-borrow completion log gate
SURVIVED L312/L314: '!=' on auth-token / cookies log guards
```

### Check 6 — Build + verify-pr

```
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath /tmp/dd-wave4-drm build 2>&1 | tail -5
** BUILD SUCCEEDED **

$ xcodebuild -project Palace.xcodeproj -scheme Palace-noDRM \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath /tmp/dd-wave4-noDRM build 2>&1 | tail -5
** BUILD SUCCEEDED **
```

Both targets clean.

`scripts/verify-pr.sh --quick` has a pre-existing `DIFF_BASELINE: unbound
variable` shell bug at line 264 (unrelated to Path X; happens on the
uncommitted-large-changeset path). The build leg fails because the script
isolates its own derivedDataPath and the worktree submodule typechanges
(`adept-ios`, `adobe-content-filter`, etc., shown in `git status` as
` T `) confuse the fresh build context. Targeted `xcodebuild build` runs
above succeeded, and the targeted test suite passed 140/140. Recommend
the integrator handle the verify-pr.sh shell bug separately.

### Check 6b — Targeted test suite (DoD #7)

```
$ DD=/tmp/dd-wave4-test
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath "$DD" \
    -only-testing:PalaceTests/BookDetailViewModelTests \
    -only-testing:PalaceTests/BookCellModelStreamingHTMLTests \
    -only-testing:PalaceTests/DownloadStartDispatcherTests \
    -only-testing:PalaceTests/BorrowOperationStreamingHTMLTests \
    -only-testing:PalaceTests/BookButtonMapperTests \
    -only-testing:PalaceTests/StreamingReaderPresentationContractTests \
    test 2>&1 | tee /tmp/test-wave4.log | tail -5
Executed 140 tests, with 0 failures (0 unexpected) in 1.873 (2.002) seconds
** TEST SUCCEEDED **

$ ls "$DD/Logs/Test/"*.xcresult
/tmp/dd-wave4-test/Logs/Test/Test-Palace-2026.06.03_15-10-57--0400.xcresult
```

### Check 7 — Multi-step / wiring-claim coverage

The 4 new dispatcher tests directly invoke
`dispatcher.processDownloadWithCredentials(...)` and assert on the
recording spy delegate's state. The cited production line
(`DownloadStartDispatcher.swift:200-203`, the early-return) is exercised
on every iteration. The mutation report confirms the `==` and surrounding
predicate mutants on those lines are killed — proves the cited lines have
non-zero coverage from the named tests.

### Check 8 — Contract reconciliation

```
$ python3 scripts/check-contract-reconciliation.py --commit-msg /tmp/wave4-commit-msg.txt
OK: no claims parsed from any source.
EXIT: 0
```

(The draft commit msg uses neutral verbs — "reverts", "adds" — that the
script's claim parser doesn't trigger on. The diff matches the commit
body exactly: a single +12-LOC early-return in the dispatcher, two narrow
reverts in the action handlers.)

### Check 9 — Blast-radius

```
$ python3 scripts/check-blast-radius.py --quiet
EXIT: 0
```

No new public API, no `#if DEBUG` on production paths, no test-only init
params, no discarded function results.

### Check 10 — Adjacency staleness

```
$ python3 scripts/check-adjacency-staleness.py --quiet
EXIT: 0
```

No production types removed or renamed.
