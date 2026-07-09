# CP-D1 (LaunchHydration) — implementer transcript (swarm_27c181b5, Wave C)

## Summary
Split `AccountsManager`'s launch-time account hydration into a SLIM synchronous
path + an off-main full materialization, per the profiling that UNBLOCKED D1
(~207ms on a fast sim: 95ms decode + 112ms mapping 1142 accounts, all on the
launch main thread pre-window). On launch we now decode ONLY the current +
settings accounts (a few KB) synchronously so `currentAccount` resolves and its
`Account.awaitReady()` gate is driven immediately; the full 1142-account
decode+map moves off the launch main thread onto the background `loadCatalogs`
the initializer already dispatches. State lives in `AccountStateStore` keyed by
uuid, so it survives the slim→full Account-instance swap.

## Slim/full boundary decision (Phase 1a correction #2) — **Option (a)**
The slim set lands in a **separate** `slimAccountsByUUID` structure, NOT in
`accountSets`. `account(_:)` returns the full instance if present, else falls
back to the slim one — so `currentAccount` resolves during the pre-materialization
window, while `accountsHaveLoaded` (`!accountSets[accountSet].isEmpty`) and
`accounts()` keep reflecting the FULL 1142-account list. This means the library
picker (`TPPAccountList:56` / `TPPAppDelegate.presentFirstRunFlowIfNeeded:595`)
never sees a truncated ~2-account list — it either waits on the not-yet-loaded
gate (the pre-existing `.TPPCatalogDidLoad`-observer path those consumers already
had) or sees the full list once materialized. **No picker-consumer files were
touched** — the boundary stayed entirely inside `AccountsManager`, so no
scope-deferral was needed. A picker-full-count test pins that `accounts()` reaches
the full fixture count (171), not the slim count (2).

Full materialization reuses the EXISTING background `loadCatalogs` (dispatched by
`init` right after preload): with `accountSets` empty, `loadCatalogs` takes its
disk-cache branch → `loadAccountSetsAndAuthDoc` → fills `accountSets` (full) and
posts `.TPPCatalogDidLoad`. No new off-main materialize path was added — minimal
surface.

## Slim snapshot persistence
- New file `accounts_catalog_slim_<hash>.json` (shares the `accounts_catalog_`
  prefix, so `clearCache()` and the wiring-suite purge already sweep it).
- Written **off-main** (`Task.detached(.utility)`, cooperative-cancel guarded,
  registered via `_trackCrawlTask`) by carving the current+settings catalog
  entries out of the authoritative full blob via `JSONSerialization`
  (`carveSlimFeed`). Carving RAW JSON (not re-encoding decoded models) preserves
  the exact date-string format `OPDS2CatalogsFeed.fromData`'s custom date decoder
  expects — no encoder date-strategy hazard.
- Read back synchronously at launch through the SAME `OPDS2CatalogsFeed.fromData`
  reader.
- First launch after this ships (or fresh install): no slim file yet ⇒ the SLOW
  path runs the original full-sync hydrate unchanged, then seeds a slim snapshot
  off-main for the next launch. The slim fast path is gated on
  `hasCachedCatalogData` (full-cache freshness) so a truly-expired cache still
  no-ops — `testPreload_expiredMetadata_doesNotHydrate` semantics preserved.

## Files changed
- `Palace/Accounts/Library/AccountsManager.swift`
  - `slimAccountsByUUID` + `slimAccountsLock` (separate slim lookup).
  - `preloadAccountsFromDiskCacheSync` rewritten: slim fast path + full slow
    path + off-main slim seed. Helpers: `hydrateSlimLaunchSnapshot`,
    `hydrateFullAccountSets` (factored original body), `storeSlimAccounts`,
    `slimAccount`, `refreshSlimLaunchSnapshotOffMain`, `writeSlimSnapshot`,
    `slimSnapshotUUIDs`, `carveSlimFeed` (internal-static, pure), `slimSnapshotUrl`.
  - `account(_:)`: full-then-slim fallback.
  - `loadAccountSetsAndAuthDoc`: the non-carry-over `else` now guards on
    `.notLoaded` so the async full-list materialization can't downgrade a
    slim-advanced (mid-flight) current account back to `.basicInfoLoaded`.
  - `hydrateFullAccountSets` / `hydrateSlimLaunchSnapshot`: only stamp
    `.basicInfoLoaded` on still-`.notLoaded` uuids (no-downgrade).
- `Palace/AppInfrastructure/AppContainer.swift`: doc comment at the
  `AccountsManager()` construction site — `production()` no longer eager-hydrates
  the full account list; do not reintroduce a synchronous full preload here.
  (Region distinct from Wave A's A5 shared-repo region.)
- `PalaceTests/Accounts/AccountsManagerLaunchSnapshotTests.swift` (NEW; added to
  PalaceTests target via `pbxproj_add_swift.rb`).

## Tests (`AccountsManagerLaunchSnapshotTests`, subclass of `PalaceWiringTestCase`)
1. `testPreload_slimSnapshotPresent_hydratesOnlyCurrentAndSettings_notFullList` —
   slim correctness: `currentAccount` resolves, but `accountsHaveLoaded == false`
   and `accounts()` empty (slim did NOT leak into `accountSets`); an account
   outside the slim set does not resolve; current account advanced past `.notLoaded`.
2. `testPreload_slimSnapshotButNoFullCache_doesNotHydrate` — slim fast path gated
   on full-cache freshness.
3. `testPicker_fullListMaterializes_reachesFullCount_notSlimCount` — after driving
   the full list via the production seam (`loadAccountSetsAndAuthDoc`),
   `accounts()` reaches the FULL fixture count and `accountsHaveLoaded` is true.
4. `testRoundTrip_slimHydratedCurrentAccount_reselectAwayAndBack_redrivesViaProductionSeam`
   — write→reset→re-enter through production seams (slim preload → `currentAccount`
   setter A→B evicts A → setter B→A re-drives A off the stale
   `.detailsEvicted(.libraryDeselected)` marker). Modeled on
   `testLibraryReselect_reentry_resetsState_andRedrives` (:818). No `_setState`
   shortcuts in the drive path.
5. `testConsumerSmoke_readinessGateDriven_afterColdLaunch_andAfterLibrarySwap` —
   the `awaitReady()` gate is DRIVEN (reaches `.detailsLoading`/terminal) for the
   current account after cold launch AND after a library swap, so consumers don't
   hang.
6. `carveSlimFeed` pure unit tests: keeps only requested uuids + round-trips
   through the production reader; nil on no-match / empty keep-set / malformed data.

## Integration follow-up — eviction-vs-switch-cancellation ordering bug (BOTH A + B)
Integration surfaced one failing test
(`testRoundTrip_…reselectAwayAndBack_redrivesViaProductionSeam`): "A→B switch
must evict A to .detailsEvicted; got detailsFailed". Investigated — it is BOTH,
and the RIGHT layer was fixed for each:

- **(A) network isolation — already covered.** `PalaceTestSetup` installs
  `NoNetworkURLProtocol` via `AppContainer.testExecutorProtocolClasses`, so the
  auth-doc `AppContainer.production().networkExecutor.GET` is blocked, not real.
  The "real hosts" in the run log are `NoNetworkURLProtocol` *blocked-URL* log
  lines + `-999` cancellations, not real traffic. My tests never call
  `loadCatalogs` (no registry crawl); they use `loadAccountSetsAndAuthDoc`. No
  new stubbing needed.
- **(B) REAL production ordering bug — fixed.** The `currentAccount` setter
  cancels A's in-flight auth-doc fetch (`cancelNonEssentialTasks`, ~:643) THEN
  writes `.detailsEvicted(.libraryDeselected)` (~:612). The cancelled fetch's
  async completion (`success == false`, NSURLError -999) then wrote
  `.detailsFailed`, **clobbering the eviction marker**. On switch-back,
  `driveCurrentAccountAuthDocIfNeeded` reads `.detailsFailed` → the "genuine
  failure, don't redrive" arm → `awaitReady()` consumers (audiobook open, token
  refresh, bookmark sync, CarPlay auth) stay stuck — the exact regression class
  PR #1021 split the enum to prevent. CP-D1's slim-preload widened the window
  (the current-account drive now fires at launch), so the test caught a latent
  bug. **Fix:** `fetchAuthDocumentWithStateMachine`'s completion now guards its
  terminal write via the new pure `AccountsManager.fetchCompletionMayWriteTerminal(currentState:)`
  — a superseded (evicted) account's completion must NOT overwrite the newer,
  deliberate `.detailsEvicted` terminal (success or failure). The normal path is
  unaffected: the fetch entry sets `.detailsLoading` first, so a non-clobber
  completion always sees a non-evicted state and writes its real outcome.
  The assertion was NOT loosened to accept `.detailsFailed`.

  Tests: `testFetchCompletionMayWriteTerminal_evictedSuppressesWrite_othersAllow`
  (pure, deterministic mutation-killer: only `.detailsEvicted` → false; the other
  five states → true) + the round-trip test strengthened with an async settle
  window that re-asserts A is still `.detailsEvicted` after the cancelled fetch's
  completion fires (end-to-end guard proof).

## Second integration follow-up — cross-test pollution from the slim-write task
The eviction fix (B) rebuild surfaced one more regression:
`AccountsManagerStateMachineWiringTests.testDriveCurrentAccountAuthDoc_terminalState_isNoOp`
failed "currentAccount must resolve after preload". Root cause: my
`refreshSlimLaunchSnapshotOffMain` spawned a detached best-effort slim-file write
that outlived the writer test (cooperative cancel can't stop an in-progress
`Data.write`), leaking an `accounts_catalog_slim_<hash>.json` — whose slim uuids
were the writer's — into a sibling test's launch, flipping it onto the slim fast
path with a non-matching current account (→ nil). Fix: gate the background
slim-write SPAWN on the same `Self._isRunningUnderXCTest` runtime env gate
`_trackCrawlTask` uses (BR-2: runtime gate, not `#if DEBUG`). Production always
refreshes; tests seed slim snapshots explicitly, so no fast-path coverage is
lost. `carveSlimFeed`/`writeSlimSnapshot` logic stays unit-tested via
`carveSlimFeed` directly.

## Build + test evidence (sim 141BD227-6E9A-4409-8D99-2D4FE818238D, isolated DerivedData)
`-only-testing` the two touched classes (scoped spot-check for this targeted fix,
NOT a full-suite claim): **`** TEST SUCCEEDED **`**.
- `Test Suite 'AccountsManagerLaunchSnapshotTests' passed` — Executed 10 tests, 0 failures.
- `Test Suite 'AccountsManagerStateMachineWiringTests' passed` — Executed 13 tests, 0 failures.
- `Test Suite 'Selected tests' passed` — Executed 23 tests, 0 failures. No
  `exceeded execution time allowance` / `Restarting after … timeout` lines.
Build compiled clean (warnings only). Static checks after final edits:
name-vs-body / blast-radius / superpartner / adjacency all exit 0.

## Architect SoD review follow-up — Findings 4 & 5 (both BLOCKING, both fixed)

**Finding 4 — slim→full instance split-brain (currentAccount.details==nil while state=.detailsLoaded).**
`details`/`authenticationDocument` are per-INSTANCE stored properties; the slim
current-account drive fetches the auth-doc onto the SLIM instance, but the full
materialization built fresh instances and `oldAccountsByUUID` (=accountSets) is
empty on a slim-only launch, so the full current instance never inherited it, and
the self-heal re-drive is deduped by the single-flight guard if the slim fetch is
still in-flight. **Fix:** in `loadAccountSetsAndAuthDoc`'s `newAccounts` map, REUSE
the existing slim instance for a uuid when `oldAccountsByUUID[uuid] == nil` (the
launch materialization) — keeps ONE Account per uuid so an in-flight fetch lands on
the instance that becomes `currentAccount`. Bounded to launch: on warm/network-
refresh paths `accountSets` is populated → `oldAccountsByUUID` non-nil → fresh
network instances win (carry-over inherits the auth-doc). **Test:**
`testSlimToFull_reusesSlimCurrentAccountInstance_soInFlightAuthDocNotStranded` —
asserts instance identity across the transition AND that an auth-doc set on the
slim instance after materialization surfaces on `currentAccount.details`.

**Finding 5 — stale slim snapshot lacking the now-current account → transient nil currentAccount.**
The slim file is written from the launch-time current account and was NOT rewritten
on a mid-session switch, so a stale slim file can lack the now-current account;
`hydrateSlimLaunchSnapshot` still returned true (non-empty) → fast path returns
without the full hydrate → `currentAccount` nil in the pre-materialization window.
**Fix (both belt + suspenders):** (a) `refreshSlimLaunchSnapshotOffMain(hash:)` is
now also called from the `currentAccount` setter (switch) so the slim file tracks
the new current account; (b) `hydrateSlimLaunchSnapshot` returns false (falls
through to the full sync hydrate) when the decoded slim set does NOT contain
`currentAccountId`. **Test:**
`testPreload_staleSlimSnapshotLacksCurrentAccount_fallsThroughToFullHydrate` —
seeds a slim file lacking the current account, asserts `currentAccount` resolves +
the FULL list materializes.

**F6 (dedup-vs-cancel on rapid A→B→A):** per the architect, pre-existing and
non-blocking; left as their tracked follow-up.

## Definition-of-Done evidence
- **Check 1 (SUT instantiation):** `grep -cE "AccountsManager\.|makeFreshAccountsManager|AccountsManager\("`
  → 11 (≥1). `check-test-name-vs-body.py PalaceTests/Accounts/AccountsManagerLaunchSnapshotTests.swift`
  → `OK, 0 fake-wiring tests`, exit 0.
- **Check 3 (multi-step body):** the `roundTrip…reselectAwayAndBack` and
  `…afterColdLaunch_andAfterLibrarySwap` bodies literally perform each named step.
- **Check 4 (scope):** all four contracted test kinds (slim correctness /
  round-trip / consumer smoke / picker-full-count) landed; boundary decision +
  picker-count test present. No scope reduction.
- **Check 9 (blast-radius):** `check-blast-radius.py --quiet` → exit 0.
- **Check 10 (adjacency):** `check-adjacency-staleness.py --quiet` → exit 0.
- **Check 11 (superpartner):** `check-superpartner-spectrum.py --quiet` → exit 0
  (0 items missing a test).
- **pbxproj:** `AccountsManagerLaunchSnapshotTests` present (4 entries, PalaceTests target).
- **Brace/paren balance:** 0/0 on all three changed files.

## Deferred to integrator (per task constraint "do NOT run git or a full app build")
- **Check 5 (mutation ≥80% diff-scoped):** requires a sim build (frameworks
  absent in a fresh worktree; `palace_mutate.py`/`verify-pr.sh` need a sim UDID).
  Intended mutant→killer map for the integrator to run
  (`palace_mutate.py --file Palace/Accounts/Library/AccountsManager.swift
  --tests PalaceTests/AccountsManagerLaunchSnapshotTests --diff-only`):
  - `carveSlimFeed` filter (`keepUUIDs.contains(id)`, `!kept.isEmpty`) →
    `testCarveSlimFeed_*` (keep-only / no-match-nil / empty-nil).
  - slim/full boundary (slim NOT in `accountSets`) →
    `testPreload_slim…_notFullList` (`accountsHaveLoaded == false`) +
    `testPicker_full…_reachesFullCount`.
  - `account(_:)` full-then-slim ordering → `testPreload_slim…` (current resolves
    via fallback) + `testPicker…` (full wins after materialize).
  - `hasCachedCatalogData` fast-path gate → `testPreload_slimSnapshotButNoFullCache_doesNotHydrate`.
  - eviction-redrive round-trip → `testRoundTrip_…reselectAwayAndBack`.
- **Check 6 (build + verify-pr):** integrator runs on a sim per the swarm
  convention (same as the Accounts-Startup transcript).
