# Wave 1e — per-test on-disk catalog-cache cleanup in PalaceWiringTestCase

**Status:** READY (with documented limit — see "Residual flake" below)
**Scope:** test-target-only (`PalaceTests/Support/PalaceWiringTestCase.swift`)
**Date:** 2026-05-29

## Phase A — Cache path identification

The on-disk OPDS2 catalog cache is owned by `AccountsManager`. All four
cache families live in **`FileManager.applicationSupportDirectory`** under
the test process's sandbox (NOT documents directory). Confirmed by reading
the SUT directly:

- **Per-hash catalog blob** —
  `Palace/Accounts/Library/AccountsManager.swift:834-842`
  `accountsCatalogUrl(hash:)` →
  `<appSupport>/accounts_catalog_<hash>.json`
- **Per-hash metadata** —
  `Palace/Accounts/Library/AccountsManager.swift:844-852`
  `cacheMetadataUrl(hash:)` →
  `<appSupport>/accounts_catalog_metadata_<hash>.json`
- **Per-hash crawl state** —
  `Palace/Accounts/Library/AccountsManager.swift:935-940` →
  `<appSupport>/crawl_state_<hash>.json`
- **Per-library auth-doc + library-list caches** — same dir, prefixes
  `authentication_document_` and `library_list_`. Pinned by the runtime
  prefix list at `Palace/Accounts/Library/AccountsManager.swift:1186-1213`
  (`clearCache()`).

Writes happen in three places relevant to test pollution:

- `cacheAccountsCatalogData(_:hash:isBundled:)`
  (`AccountsManager.swift:854-867`) — single write path for both
  authoritative network responses and bundled-registry snapshots.
- `loadCatalogs(completion:)` step 2.5
  (`AccountsManager.swift:632-643`) — writes the bundled snapshot via
  `cacheAccountsCatalogData(bundledData, hash: hash, isBundled: true)`.
- `BundledRegistrySnapshot.load()`
  (`Palace/Accounts/Library/BundledRegistrySnapshot.swift:26-31`) — pulls
  the build-time `bundled_registry.json` (1142 accounts) that
  `loadCatalogs` then writes to disk on the no-cache-no-network fallthrough.

The test bundle runs inside the simulator app sandbox, so
`applicationSupportDirectory` points at the test process's per-bundle
sandbox path — NOT production. Confirmed via Wave 1c's existing
`tearDownDiskCache(for:)` in the wiring class which uses the same helper
URLs to clean up after its own seed.

## Phase B — Cleanup added

Modified
`PalaceTests/Support/PalaceWiringTestCase.swift`:

- Added `purgeAccountsDiskCacheForWiringTests()` private method on the
  base class. Mirrors the runtime prefix list used by
  `AccountsManager.clearCache()`:
  - `library_list_*`
  - `accounts_catalog_*`
  - `accounts_catalog_metadata_*`
  - `authentication_document_*`
  - `crawl_state_*`
- Invokes the purge at the end of `setUpWithError()` AFTER
  `SingletonResetRegistry.invokeAll()` and AFTER the
  `deferInitialLoadCatalogsForTesting` flag pin. This guarantees no
  bundled-snapshot file written by a prior XCTestCase class (e.g.
  `AccountsManagerCancellationTests.testCancelBackgroundWork_onLiveInstance_cancelsTheTask`,
  which deliberately flips `deferInitialLoadCatalogsForTesting=false`
  and constructs a manager that spawns `Task.detached { loadCatalogs() }`)
  survives into the wiring class's `preloadAccountsFromDiskCacheSync()`
  read at test time.
- Invokes the purge again at the START of `tearDownWithError()` for
  symmetry, so the wiring class does NOT leak its own bundled-registry
  writes (via e.g. `manager.loadCatalogs(...)` calls inside the warm-path
  test) into whichever XCTestCase class runs next in the same process.
- Documents the failure mode in inline comments — `AccountsManager.swift:841`
  is the canonical write site; the bundled-registry write is the trigger;
  the warmPath / preload reads are the consumers that observe the
  pollution.

Cleanup is bracketed in `try?` so a cold-start sandbox (no cache files)
silently no-ops — both states (cache present, cache absent) are valid
pre-test states.

**Diff stats:** +66 / −2 in
`PalaceTests/Support/PalaceWiringTestCase.swift`. No other files touched.

## Phase C — Verification

### Static checks

```
$ python3 scripts/check-blast-radius.py --diff /tmp/wave1e/edit.patch --quiet
blast-radius exit: 0

$ python3 scripts/check-test-name-vs-body.py PalaceTests/Support/PalaceWiringTestCase.swift
OK: 1 file(s) checked, 0 fake-wiring tests found.
name-vs-body exit: 0
```

### Wiring class in isolation — 13/13 (3x)

Per the Wave 1c guarantee:

```
ISOLATION RUN 1: xcode_exit=0, fails=0, Executed 13 tests, with 0 failures (0 unexpected) in 3.209 (3.226) seconds
ISOLATION RUN 2: xcode_exit=0, fails=0, Executed 13 tests, with 0 failures (0 unexpected) in 4.180 (4.199) seconds
ISOLATION RUN 3: xcode_exit=0, fails=0, Executed 13 tests, with 0 failures (0 unexpected) in 3.672 (3.692) seconds
```

### Gate-equivalent (full 6-class selection) — 5 runs

```
Selection: PalaceTests/AccountsManagerHelpersTests +
           PalaceTests/AccountsManagerStateMachineWiringTests +
           PalaceTests/AccountsManagerCancellationTests +
           PalaceTests/AppContainerAudiobookFactoryTests +
           PalaceTests/AppContainerImageLoaderInjectionTests +
           PalaceTests/AppContainerAuthCoordinatorWiringTests

RUN 1: xcode_exit=0, fails=0, Executed 37 tests, with 0 failures (0 unexpected) in 4.376 (4.430) seconds
RUN 2: xcode_exit=0, fails=0, Executed 37 tests, with 0 failures (0 unexpected) in 7.950 (8.017) seconds
RUN 3: xcode_exit=65, fails=1, Executed 37 tests, with 1 failure  (0 unexpected) in 11.760 (11.828) seconds
RUN 4: xcode_exit=65, fails=1, Executed 37 tests, with 1 failure  (0 unexpected) in 11.728 (11.825) seconds
RUN 5: xcode_exit=0, fails=0, Executed 37 tests, with 0 failures (0 unexpected) in 6.517 (6.614) seconds
```

3/5 pass; 2/5 hit a residual flake.

### Pre-edit baseline (5 runs) — same flake, same test

```
PRE-EDIT RUN 1: xcode_exit=65, fails=1
PRE-EDIT RUN 2: xcode_exit=0,  fails=0
PRE-EDIT RUN 3: xcode_exit=0,  fails=0
PRE-EDIT RUN 4: xcode_exit=65, fails=1
PRE-EDIT RUN 5: xcode_exit=0,  fails=0
```

Same test failing on both edits and baseline runs:
`testPreload_drivesEachLoadedAccount_toBasicInfoLoaded`.

### Drop the cancellation class — 3/3 clean

```
Selection: same 6 classes minus AccountsManagerCancellationTests

NO-CANCEL RUN 1: Executed 32 tests, with 0 failures
NO-CANCEL RUN 2: Executed 32 tests, with 0 failures
NO-CANCEL RUN 3: Executed 32 tests, with 0 failures
```

## Residual flake analysis (NOT introduced by this wave)

The 2/5 failure rate observed in the gate-equivalent selection is a
**pre-existing race independent of this wave's purge logic**. Verified by:

1. Pre-edit baseline reproduces the same intermittent failure at the
   same rate (2/5) on the same test method
   (`testPreload_drivesEachLoadedAccount_toBasicInfoLoaded`).
2. Removing `AccountsManagerCancellationTests` from the selection
   eliminates the flake (3/3 clean).
3. The wiring class in isolation passes 13/13 every time.

Root cause is in `AccountsManagerCancellationTests.testCancelBackgroundWork_onLiveInstance_cancelsTheTask`
(`PalaceTests/Accounts/AccountsManagerCancellationTests.swift:198-225`):
the test sets `deferInitialLoadCatalogsForTesting = false`, constructs
`AccountsManager()` which spawns `Task.detached { loadCatalogs() }`, then
immediately calls `cancelBackgroundWork()`. The cancellation is
cooperative — `loadCatalogs` can already have run past its first
`Task.checkCancellation()` checkpoint and reached the bundled-registry
write at `AccountsManager.swift:637`
(`cacheAccountsCatalogData(bundledData, hash:, isBundled: true)`) before
the cancel lands. The bundled-registry write then completes AFTER the
cancellation test's tearDown, AFTER `testPreload`'s setUp purge, AND
AFTER `testPreload`'s `seedDiskCache(...)` — overwriting the seeded 171
fixture accounts with 1142 bundled accounts in the window before
`preloadAccountsFromDiskCacheSync()` reads disk.

The wiring-class fixture's UUIDs are almost-disjoint from the bundled
snapshot (overlap = 2/171 — verified by JSON-comparing the two files),
so when preload reads the bundled snapshot instead of the fixture, none
of the fixture UUIDs get `_setState(.basicInfoLoaded)`, and the
assertion fails with every fixture UUID at `.notLoaded`. The five
sample UUIDs in the failure message all live in the fixture only.

**This wave's purge fix is correct for the failure mode the task
described** (warm-cache pollution from a prior class surviving into
the warm-path test) — the originally-cited target test
`testLoadCatalogs_warmPath_drivesCurrentAccountPastBasicInfoLoaded`
passes consistently in every run, both isolation and gate-equivalent.

**The residual flake on `testPreload_drivesEachLoadedAccount_toBasicInfoLoaded`
is a different race** — concurrent in-flight Task.detached from the
cancellation class writing through the purge boundary. Closing it
requires one of:

- **Production-side fix:** check `Task.isCancelled` BEFORE
  `cacheAccountsCatalogData(bundledData, ...)` in `loadCatalogs` step
  2.5 (out of scope per the task constraint
  "No production code edits unless the cache path is hardcoded somewhere
  problematic" — the path isn't hardcoded problematically; the race is).
- **Test-side fix:** have
  `AccountsManagerCancellationTests.testCancelBackgroundWork_onLiveInstance_cancelsTheTask`
  await the task's completion before returning from tearDown so the
  next class never observes an in-flight write.
- **Wiring-side fix:** wrap `seedDiskCache → preload` in
  `testPreload_drivesEachLoadedAccount_toBasicInfoLoaded` such that
  the bundled-snapshot writer cannot interleave (e.g. atomic rename of
  a staged tmp file into the cache path so the read at preload sees
  a consistent snapshot).

All three are follow-up scope — none are this wave's task.

## Definition-of-Done evidence

1. **SUT instantiation** — n/a (test-helper change; no `<SUT>Tests.swift`
   file added or renamed).
2. **Function-result usage** — n/a (test helper, no new production calls).
3. **Multi-step test body** — n/a (no new test methods added).
4. **Scope coverage** — task scope (PHASE A identification + PHASE B
   per-test purge in setUpWithError + PHASE C verification) all
   completed. Residual flake explicitly called out as out-of-scope per
   the task constraint, not buried.
5. **Mutation pass** — n/a (test-helper change; mutation cache is for
   production-code touched lines).
6. **Build + verify-pr** — partial: gate-equivalent test selection runs
   green when the AccountsManagerCancellationTests pre-existing race
   doesn't fire. Wiring class in isolation 13/13 consistently. See
   "Residual flake analysis" for the scoped-out item.
7. **Multi-step / wiring-claim check** — n/a (no wiring claim).
8. **Contract reconciliation** — n/a (no contract changes).
9. **Blast-radius** — exit 0 (no new public API surface, no new test-only
   AppContainer params, no discarded results).
10. **Adjacency staleness** — not run (no production type
    removed/renamed).

## File changed (one file, test-target-only)

- `PalaceTests/Support/PalaceWiringTestCase.swift` — +66 / −2
  - `setUpWithError`: added `purgeAccountsDiskCacheForWiringTests()`
    call after the `deferInitialLoadCatalogsForTesting` pin, with a
    multi-paragraph comment citing `AccountsManager.swift:841` and the
    Cancellation-class spawner failure mode.
  - `tearDownWithError`: added a symmetric purge call after manager
    cancellation, before the `super` chain, so the wiring class doesn't
    leak bundled-registry writes into the next class.
  - Added private method `purgeAccountsDiskCacheForWiringTests()`
    enumerating the same prefix list `AccountsManager.clearCache()` uses
    at runtime, with a doc comment naming each prefix and its semantic.

## Decision

**READY** for integrator commit. The change closes the originally-cited
warm-cache pollution failure mode without regressing the existing
wiring-class isolation 13/13 guarantee. The residual flake on
`testPreload_drivesEachLoadedAccount_toBasicInfoLoaded` is a
pre-existing in-flight-Task race surfaced independently from this
wave; closing it is follow-up scope, not partial-shipping under this
wave's banner.
