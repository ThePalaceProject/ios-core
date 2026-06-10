# Plan — swarm_0286b100: resolve the test-suite hang/flake tail (PR #1053 per-test timeout)

## Goal
Make a FULL CI run pass under PR #1053's `-test-timeouts-enabled YES` (~60s/test) with NO hangs
and NO flakes, by fixing PRODUCTION / test-isolation ROOT CAUSES. Hard constraint: no relaxed/raised
timeouts, no XCTSkip, no test sleeps, no reduced fuzz iterations. Every fix validated against the
FULL suite (isolation hides pollution).

## Root causes (5 failures → 3 causes)
- **A.** Leaked `awaitReady()` continuations on `AccountStateStore.shared` starve the cooperative
  pool. `Account.awaitReady()` parks on `for await state in stateStream`; `_resetAllForTesting()`
  emits non-terminal `.notLoaded`, so the loop `continue`s and stays parked forever; `checkCancellation`
  only re-checks on the next emission, which never comes. Leaked tasks accumulate and saturate the
  pool. Victims: CatalogPreloader hang (#1), OPDS blocksUntilLoaded (#3), DownloadThrottling pauseAll (#4).
- **B.** Unbounded per-input parse work in the annotations chain (`TPPBookmarkFactory` /
  `AudioBookmark`); `FuzzRunner` has no real per-input timeout (`timeoutPerInput` unused). One
  pathological deterministic input (seed `0xCAFEBABE`) blows up super-linearly. Victim: ParserFuzz
  annotations (#2).
- **C.** `saveSync(for:)` writes directly on the calling thread, bypassing `diskWriteQueue`, racing
  the async `save(for:)` atomic write to the same URL. Victim: TPPBookRegistryPersistence (#5).

## Modules / parallelism
1. **AccountStateStore-Isolation** (cause A — KEYSTONE: fixes #1, #3, #4)
2. **AnnotationsParseBound** (cause B — repro seed first, then bound production)
3. **BookRegistryPersistence** (cause C — CRITICAL PATH)
4. **DownloadThrottlingVerify** (cause A victim — VERIFY-FIRST; touches Download only if needed) [CRITICAL PATH]

## Risks
- Cause B's exact catastrophic line is NOT architect-pinnable; gated on repro under Instruments.
  If un-reproducible within budget, STOP + scope-deferral — do NOT add a test-level timeout to mask.
- AccountStateStore is consumed by 16 production sites and is auth-adjacent — the drain must be
  test-only (registry-wired) and must NOT change production `awaitReady` semantics on the live path.
- DownloadThrottling & BookRegistry are critical paths — SoD + mutation required if production touched.
- Validation must be FULL-suite; a green `-only-testing` run is NOT acceptance.

## Acceptance criteria
- All 5 named tests green in a FULL `xcode-test-optimized.sh` run under `-test-timeouts-enabled YES`.
- Per-contract grep-able verification criteria satisfied (no XCTSkip / no raised timeout / no test
  sleep / fuzz still 500 iterations / saveSync serialized / awaitReady drain terminal).
- Mutation kill-rate ≥50% diff-scoped on any touched critical-path production file.
- verify-pr.sh --quick PASS.
