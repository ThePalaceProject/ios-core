# Architect review (ROUND 2) — fix-contract "First-open button-label flicker" (BUG B)

**Reviewer role:** architect (independent)
**Branch:** `fix/audiobook-first-open-flicker` (contract-only; no production code staged — verified clean tree)
**Stage:** pre-implementation contract re-review. Verdict is on the CONTRACT (no branch tip/changeset gate applies yet; heka2 gate submission intentionally skipped — worktree HEAD-resolution bug heka2#7).
**Prior verdict:** BLOCKED (F1 scheduler seam missing; F2 LCP source #3 had no home/mechanism/test).
**Verdict:** **APPROVED** — both round-1 blocks are genuinely and correctly resolved. Two non-blocking warnings carry forward (a *new* line-cite regression on W1; F2 clamp-reset hygiene). Root-cause analysis, over-debounce guard, and single-cluster scope re-confirmed.

---

## Block resolution

### F1 (was concern) — RESOLVED
Scope(in) §24 now pins an injectable `scheduler` seam (default `RunLoop.main`, tests pass a virtual/immediate scheduler) into both `setupStableButtonState` pipelines. Verified both pipelines currently hardcode `scheduler: RunLoop.main` (`BookCellModel.swift:373`, `BookDetailViewModel.swift:426`) with no injection point — so the seam is both necessary and sufficient to make Test 1 (§40) authorable on a controllable clock instead of wall-clock sleeps. The seam composes cleanly: `RunLoop.main` and a test scheduler both satisfy Combine's `throttle(for:scheduler:latest:)` `Scheduler` constraint. This genuinely enables Test 1 and criterion #1. PASS.

### F2 (was concern) — RESOLVED
Scope(in) §25 now homes source #3 (LCP early `.downloadSuccessful` → Listen, then a seconds-later `.downloading` revert that lands OUTSIDE the 50 ms throttle window) as a **monotonicity clamp** in the `computeButtonState`/`stableButtonState` layer of both models — explicitly NOT in `LCPFulfillmentHandler` (kept out of scope), mirroring the existing `downloadProgress = max(...)` clamp at `BorrowReducer.swift:181` (verified present). Test 4 (§43) drives Listen → later `.downloading` and asserts Listen holds.

This is my round-1 F2 option (a), correctly scoped. It is concrete and testable, and the placement is architecturally sound: clamping inside the `map` step means the suppressed revert produces an unchanged value, so `removeDuplicates()` swallows it and nothing reaches the UI — the clamp cooperates with the existing pipeline rather than fighting it. The headline symptom (contract line 5) is now covered by a required test. PASS.

---

## Warnings (fold into implementation; non-blocking)

### W1 (carried + REGRESSED) — scope / **warning**: the optimistic-write line cite is now stale in the OTHER direction
The contract cites the optimistic write at `:839` ("architect W1 corrected the cite from `:820`"). That was correct for the round-1 tree, which was **stacked on BUG A**. The current branch is off plain `develop` (BUG A absent — no `onLoadingShellPresented`/`audiobookSession` markers present), so the file is ~19 lines shorter above this region and the write `bookState = .downloading` now lives at **`BookDetailViewModel.swift:820`** (inside `startDownloadAfterAuth`, `:819-823`); `:820` is no longer the SAML `action()` call (that is now `:805`).
Non-blocking because the method `startDownloadAfterAuth` is named and the write is the first of three body lines — the implementer cannot plausibly edit the wrong thing.
**Recommendation:** cite the optimistic write by **method + symbol** (`startDownloadAfterAuth` → the `bookState = .downloading` line), and record the absolute line as *`:820` on develop / ~`:839` when stacked on BUG A*. The A/B stacking is exactly why absolute line numbers here are fragile — anchor on the symbol. (The `setupStableButtonState` cites `:365-375`/`:416-428` and the throttle-scheduler lines `:373`/`:426` were re-verified accurate against the current tree; only the below-the-shift write cite drifted.)

### F2-note — architecture / **warning**: pin the monotonicity-clamp RESET conditions
A Listen-monotonicity clamp has the same latent failure mode as the stuck-`Cancel` bug already documented in this very file (`BookDetailViewModel.swift:385-391`): if it never yields, a genuine post-early-ready download **failure**, or a **return/cancel/delete**, could leave the button stuck on Listen with no playable content. The contract's "absent an explicit user action" language captures the intent but does not pin the reset set.
**Recommendation (implementation-time, not a re-block):** scope the clamp to a per-book/per-session flag that resets on real user actions (return/cancel/delete) and on a terminal download-error state; add an assertion to Test 4 (or a Test 4b) that the clamp DOES yield on a genuine failure/return so it can't regress into a stuck-Listen. Also ensure the clamp + its test exist in BOTH `BookCellModel` and `BookDetailViewModel`, since acceptance §49 requires the fix on both the cell and the half-sheet.

### W2 (carried) — FOLDED, with a status note
Contract §45-46 correctly folds the BUG-A coordination: disjoint line ranges, stack B on A (or rebase after A lands), re-run `AudiobookOpenStateRaceTests` + the BUG A suite. Note the current branch is off develop (A not yet present), so the "stack on A" step is still pending — that is consistent with the contract's "rebase after A lands" allowance. Re-verify the disjointness after the rebase (A's presence is what shifted the W1 line number), don't assume.

---

## Round-1 passes re-confirmed
1. **Root cause.** #1 (throttle leading+trailing) confirmed at both pipelines (`throttle(50ms, RunLoop.main, latest:true)` downstream of `removeDuplicates()`). #2 optimistic write confirmed at `:820` (see W1). #3 confirmed at `LCPFulfillmentHandler.swift:204` (`markDownloadSuccessful` after `copyLicenseForStreaming`, content still downloading). Accurate.
2. **No over-debouncing.** Guarded by Test 2 (single change emits promptly) + Test 1 asserting START **and** SETTLED (two emissions) — this pins the mechanism to immediate-leading + coalesced-trailing and rules out a pure debounce that swallows the leading emit. The guard now bites because F1 makes the emission counts exact on a virtual scheduler.
3. **Scope single-cluster.** Book + MyBooks only (`BookCellModel`, `BookDetailViewModel`, `BorrowReducer` as pattern). F2 explicitly keeps `LCPFulfillmentHandler` out. Scope(out) unchanged. Confirmed.

## Bottom line
**APPROVED.** F1 and F2 are resolved with concrete, testable, correctly-scoped mechanisms; the responsiveness guard and single-cluster scope hold. Before/while implementing: re-anchor the optimistic-write cite on the `startDownloadAfterAuth` symbol (currently `:820` on develop) rather than the stale `:839`, and pin the clamp's reset conditions + a yield-on-failure assertion so the Listen clamp can't become a stuck-Listen. Neither is a design change — proceed to implementation.
