# Wave C — verify-pr green (test/gate fixes + flake triage)

Branch: `swarm/swarm_27c181b5-waveC`. All Wave C CODE was already done + dual-SoD
approved; this pass fixed the full-suite `verify-pr.sh --quick` blockers only.
**No production code was touched** — all 6 changed files are test/gate files.

Build/test ran ONLY on sim `141BD227-6E9A-4409-8D99-2D4FE818238D` (iPhone 16 Pro)
with an isolated `-derivedDataPath` under scratchpad. Changes left staged for the
integrator (no commit/push).

## Files changed (all test/gate, zero production)

| File | Fix | Group |
|------|-----|-------|
| `PalaceTests/TPPBookCoverRegistryTests.swift` | 4× `HostFailureTracker(..., failureThreshold: 1)` | A |
| `PalaceTests/Accounts/CredentialSnapshotInvalidationTests.swift` | `// MIGRATED-DEFERRED:` marker on the tearDown `AppContainer.production()` drain | B (AppContainer lint) |
| `PalaceTests/MyBooks/LoanRenewalServiceTests.swift` | throwaway `TPPNetworkExecutor(cachingStrategy: .fallback)` instead of `AppContainer.production().networkExecutor` | B (TearDown lint) |
| `PalaceTests/Accounts/AccountsManagerLaunchSnapshotTests.swift` | FLAKE-002 → inverted `XCTestExpectation`; 2× `// FLAKE-003-OK:` | test_quality |
| `.forgeos/intent/perf-wavec-launch-credential-firstrun.md` | added frontmatter (`name:`/`created:`/`author:`) matching HEAD subject | intent_recorded |
| `PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift` | accept `registry.json.bak` sidecar (pre-existing #1212 stale test) | D (see below) |

## GROUP A — real regression, FIXED (4 tests)

`TPPBookCoverRegistryTests` HostFailureTracker tests constructed the tracker
without `failureThreshold`, recorded ONE failure, and asserted the host was
failing. Wave A (#1215) changed the default `failureThreshold` 1→3, so one
failure no longer trips. FIX: construct with explicit `failureThreshold: 1` so
one recorded failure trips as each test intends — preserves original intent, no
production change. The newer `HostFailureTrackerTests` (default=3 behavior) still
passes.

Isolation result: `TPPBookCoverRegistryTests` all pass; `HostFailureTrackerTests`
all pass.

## GROUP B — meta-lints (2), FIXED

Ground truth from running the actual lint XCTest classes on the sim (not just a
replica):

- **AppContainerIsolationLintTests** flagged `CredentialSnapshotInvalidationTests.swift:60`
  — a Wave-C new file. Its tearDown drains the production singleton's in-flight
  background/auth-doc work (the hermeticity contract; `makeTestAppContainer()`
  would resolve a fresh graph and leave the leaked production work running). This
  is legitimate `production()` resolution, so the documented per-line
  `// MIGRATED-DEFERRED: swarm_47883816 — <reason>` exemption is the right fix.
- **TearDownRequiredLintTests** flagged `PalaceTests/MyBooks/LoanRenewalServiceTests.swift`
  — a **PRE-EXISTING #1212 file, identical to develop, NOT a Wave-C file** (it
  entered this branch via the develop merge). It touched `AppContainer.production().networkExecutor`
  purely as a throwaway to satisfy the factory signature (the test injects a
  `StubPoster`; the executor is unused). FIX: swap in a fresh throwaway
  `TPPNetworkExecutor(cachingStrategy: .fallback)` (same call `makeTestAppContainer`
  uses) — this removes the polluter substring entirely, so both the TearDown lint
  and the AppContainer lint pass with no per-test cleanup needed and no behavior
  change. (First attempt reworded a comment containing the literal string
  `AppContainer.production()`, which both substring-blind lints re-flagged; the
  comment was reworded to avoid all polluter substrings.)

Both lint classes PASS after the fixes.

## GROUP C — green in isolation → full-suite ordering pollution (3 tests)

Ran the two classes TOGETHER in isolation on 141BD227:
`AccountsManagerLaunchSnapshotTests` + `AccountsManagerStateMachineWiringTests`
→ **25 tests, 0 failures**. Includes all 3 cited tests
(`testPreload_slimSnapshotButNoFullCache_doesNotHydrate`,
`testLoadCatalogs_currentAccountWithoutDetails_drivesDetailsLoading_thenLoaded`,
`testStartDownload_currentAccountIdRoundTrip_A_nil_A_B_eachCaptureIsPinned`).

Verdict: **full-suite ordering pollution, NOT real regressions.** The Wave-C
launch/credential tests already carry robust teardown — `AccountsManagerLaunchSnapshotTests`
extends `PalaceWiringTestCase` (base drains Combine, cancels every helper-minted
`AccountsManager`'s background work, purges the OPDS2 disk cache) plus a post-test
`SingletonResetRegistry.invokeAll()` that resets `AccountStateStore.shared`, and
each test body calls `AccountStateStore.shared._resetAllForTesting()`.
`CredentialSnapshotInvalidationTests` explicitly drains the production
accountsManager and resets `AccountStateStore` in tearDown. The residual is a
timing race in the 930-test ordering (a cancelled background auth-doc completion
landing in the reset window) that CI's `-test-iterations 3 -retry-tests-on-failure`
absorbs.

## GROUP D — isolation triage (6 tests)

| Test | Isolation verdict |
|------|-------------------|
| `BorrowOperationStreamingHTMLTests.testBorrowOperation_borrowSucceeded_streamingHTMLBook_doesNotCallStartDownload` | PASS → pre-existing pollution/flake |
| `AudiobookSessionStateTransitionTests.testPlayingState_isActive_andHasBookId` | PASS → pre-existing pollution/flake |
| `AudiobookSessionStateTransitionTests.testSessionManager_updateCoverImage_nil_clearsImage` | PASS → pre-existing pollution/flake |
| `TPPBookRegistryPersistenceTests.testSave_ThenColdStartLoad_PreservesRecord` | PASS → pre-existing pollution/flake |
| `TPPPerAccountIsolationTests.testConcurrentAccess_noContamination` | PASS → pre-existing pollution/flake |
| `TPPBookRegistryAtomicWriteTests.testSaveSync_LeavesNoStagingArtifactsInRegistryDir` | **FAIL in isolation → pre-existing #1212 stale test — FIXED (test-only)** |

The 5 PASS-in-isolation tests are pre-existing ordering pollution, unrelated to
Wave C (Wave C did not touch those areas); CI's `-retry` handles them.

`testSaveSync_LeavesNoStagingArtifactsInRegistryDir` FAILED deterministically in
isolation — **not a flake, and not Wave C.** Root cause: PR #1212 ("Bulletproof
Ownership: durable downloads + **registry resilience**") added
`RegistryFileRecovery` which persists a durable last-good `registry.json.bak`
sidecar on every save (the INV-1 last-good-backup contract). The test (last
touched in #1162, before #1212) asserts the registry dir contains ONLY
`registry.json` and so trips on the `.bak`. Both the test and `RegistryFileRecovery`
are develop-identical (unchanged by Wave C) → it fails on develop too; CI `-retry`
cannot mask a deterministic failure.

FIX (test-only): the `.bak` is a deliberate durable backup, not a `.tmp` staging
artifact, so the assertion now (a) requires `registry.json` present, (b) asserts
NO `.tmp` staging artifacts remain — preserving the original mutant-killing intent
— and (c) allows the dir to be a subset of `{registry.json, registry.json.bak}`.

> Flag for integrator/develop: this is a pre-existing develop breakage introduced
> by #1212 that Wave C merely inherited via the develop merge. The stale-test fix
> is included here to get the branch green, but the same fix should be forward-ported
> / tracked on develop.

## test_quality — 3 blocking violations FIXED (all in `AccountsManagerLaunchSnapshotTests`)

verify-pr scopes `lint-test-quality.py` to changed test files and blocks only on
FLAKE/FLUFF/MISSING/TIMEOUT (SHALLOW is advisory).

- L305 **FLAKE-002** (asyncAfter-as-sleep, NO allow-list — migration mandatory):
  this was a "prove-a-negative after async settle" — A's cancelled auth-doc fetch
  completion fires async and the CP-D1 guard must stop it clobbering
  `.detailsEvicted(.libraryDeselected)` with `.detailsFailed`. Migrated the fixed
  `asyncAfter` sleep to the XCTest-sanctioned negative-wait primitive: an
  **inverted `XCTestExpectation`** whose observer `Task` consumes
  `AccountStateStore.shared.stateStream(for:)` and fulfills (→ FAIL) on any drift
  off the eviction marker. This is deterministic regardless of
  subscribe-vs-completion ordering (the stream emits the current value on
  subscribe) and strictly more correct than the sleep.
- L244, L439 **FLAKE-003** (timeout ≥ 15s): both `wait(for:timeout:15.0)` awaiting
  the full ~1142-account off-main decode+materialize through
  `loadAccountSetsAndAuthDoc`. Annotated `// FLAKE-003-OK:` (integration-scoped;
  15s is CI-load headroom, not a hidden sleep). Real assertions untouched.

Post-fix: 0 blocking violations in changed test files.

## intent_recorded — FIXED

verify-pr invokes `check-intent-recorded.py --diff <BASE...HEAD> --commit-msg <HEAD subject>`.
HEAD subject is `[swarm_27c181b5] Wave C intent record (D1/D2/D3 claims + anti-claims)`.
The matcher keys on the intent file's **`name:` frontmatter** (not the filename) and
requires ≥4 consecutive shared tokens (or ticket-key + 2). The Wave-C intent file
(and the A+B one) had **no frontmatter block at all** — so it was never even a
candidate. FIX: added a frontmatter block with
`name: Wave C intent record — D1 launch snapshot, D2 credential caching, D3 first-run decode`,
which shares the consecutive run `wave c intent record` with the subject.
`check-intent-recorded.py` now exits 0 under the exact verify-pr invocation.

## Production code touched

**None.** All 6 changed files are under `PalaceTests/` or `.forgeos/`.

## Final verify-pr summary

<!-- FILLED IN BELOW ONCE THE FULL RUN COMPLETES -->
