---
name: swarm_5c8ddbd5-contract-D-LoaderDispatch
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [network]
description: Module D — Loader dispatch rewrite + OPDS shape matrix tests
---

# Module D — Loader dispatch rewrite + OPDS shape matrix tests

## In-scope files (exclusive write)
- MODIFIED `Palace/Audiobooks/AudiobookLoader.swift` (consolidate two dispatch sites into one, then route through adapter chain)
- NEW `PalaceTests/Audiobook/AudiobookLoaderDispatchTests.swift`
- NEW `PalaceTests/Audiobook/AudiobookLoaderOPDSShapeMatrixTests.swift`

## Out-of-scope (read-only)
- `Palace/Audiobooks/Vendors/*` (Modules A/B/C territory)
- `Palace/Audiobooks/LCP/LCPAudiobooks.swift` (Module C territory)
- All files in the swarm-wide don't-touch list

**Specifically read-only (existing tests that must continue to pass):**
- `PalaceTests/Audiobook/AudiobookLoaderPredicateTests.swift` — `hasRefreshableCredentials` and `looksLikeHTMLResponse` predicates move from `AudiobookLoader` to a helpers extension or stay in place; existing tests are the regression gate
- `PalaceTests/Audiobook/AudiobookLoaderTests.swift` and `AudiobookSessionManagerErrorMappingTests` — the `load()` public API is unchanged
- `PalaceTests/Audiobook/AudiobookLoaderFinalizeBuildTests.swift` — `build()`/`finalizeBuild()` is unchanged

## Behavior to preserve (test-locked)
- `load(book:completion:)` signature unchanged
- `cancel()` semantics unchanged (any pending completion resolves with `.cancelled`)
- `AudiobookLoadError` enum unchanged (no cases added or removed)
- `refreshTokenIfNeeded` + `logAccountDiagnostics` unchanged
- `build()` / `finalizeBuild()` unchanged (Cantook DRM key refresh, Manifest decode, AudiobookFactory call, DefaultAudiobookManager wiring all stay)
- `hasRefreshableCredentials` and `looksLikeHTMLResponse` static helpers stay on `AudiobookLoader` (or move to a sibling file with same access)

## Rewrite plan (two-stage, single PR)

**Stage 1: consolidate the two dispatch sites**
- `resolveManifestAndDecryptor` and `fetchOpenAccessManifest` both branch on the book's source shape. Collapse into one `resolveSource(book:) -> AudiobookSource` step that returns an enum carrying the chosen path.
- All existing tests still pass at end of Stage 1.

**Stage 2: route through adapter chain**
- Replace the `resolveSource(book:)` enum with:
  ```swift
  let adapter = adapters.first(where: { $0.canHandle(book) })
  ```
- `adapters = [lcpAdapter (if LCP), localFileAdapter, bearerTokenAdapter, openAccessAdapter]`
- The order matters: LCP > local > bearer-token > open-access
- The fallback when no adapter matches is `.manifestFetchFailed` (matches current behavior when `defaultAcquisition.hrefURL` is nil)

## Public types consumed
- `AudiobookVendorAdapter` (Module A)
- `OpenAccessAdapter`, `BearerTokenAdapter`, `LocalFileAdapter` (Module B)
- `LCPAdapter` (Module C, gated `#if LCP`)

## Tests owned (named cases)

**AudiobookLoaderDispatchTests**
- `testLoad_lcpBook_dispatchesToLCPAdapter` (under `#if LCP`)
- `testLoad_localFileBook_dispatchesToLocalFileAdapter`
- `testLoad_bearerTokenBook_dispatchesToBearerTokenAdapter`
- `testLoad_openAccessBook_dispatchesToOpenAccessAdapter`
- `testLoad_lcpPriorityOverOthers` (under `#if LCP` — even with local file present, LCP wins)
- `testLoad_noAdapterMatches_failsWithManifestFetchFailed`
- `testLoad_cancelDuringDispatch_surfacesCancelled` (regression — cancellation between adapter selection and `resolveManifest`)

**AudiobookLoaderOPDSShapeMatrixTests** (the PR #970 matrix introduced here)
- `testMatrix_OPDS1XMLFeedTopLevelLCP_routesToLCP` — the `/loans/` XML shape PP-4407 worked fine on
- `testMatrix_OPDS2JSONFeedNestedLCP_routesToLCP` — the `/groups/` JSON shape PP-4407 broke on. **Would FAIL on a property-check loader using only `canOpenBook`, PASSES on the adapter loader using `hasLCPAcquisition`** — explicit regression gate
- `testMatrix_OPDS2JSONFeedNestedLCP_propertyCheckLoaderWouldHaveFailed` — meta-test: instantiate a loader configured with the OLD top-level-only predicate and assert it routes WRONG on this fixture — locks the semantic difference into the test suite as documentation
- `testMatrix_findawayTypedManifest_routesToOpenAccessAdapter` — Findaway is toolkit-side; Palace adapter sees a regular OpenAccess book record and lets the toolkit's `AudiobookFactory` pick Findaway from `manifest.@type` during `build()`
- `testMatrix_openAccessWithBearerToken_routesToBearerTokenAdapter`
- `testMatrix_openAccessNoDRM_routesToOpenAccessAdapter`

## Acceptance criteria
- `AudiobookLoader.swift` LOC reduces by >=30% (target: ~600 -> ~400 or less)
- No callback nesting depth > 2 inside the rewritten dispatch (current code is 6 deep at `load() -> refreshTokenIfNeeded -> resolveManifest -> prepareLCPSource -> ...` — rewrite to chain at depth 2)
- 100% mutation kill rate on the new dispatch site per `palace_mutate.py --diff-only --file Palace/Audiobooks/AudiobookLoader.swift`
- All existing `AudiobookLoaderTests.swift` + `AudiobookLoaderPredicateTests.swift` + `AudiobookLoaderFinalizeBuildTests.swift` cases still pass
- `AudiobookSessionManager.swift` compiles unchanged (`loader.load(book:)` call site at line 321 must work)

## Implementer prompt

You are Module D implementer for swarm_5c8ddbd5. You depend on Modules A, B, C being merged into the orchestrator branch. Read all four contracts before starting.

Your rewrite is two-stage in one PR:
1. **Consolidate** the two dispatch sites into one (this should not change behavior — existing tests gate)
2. **Route** the consolidated dispatch through the adapter chain (LCP first, then local, bearer-token, open-access)

The `load()` public API is **frozen** — `AudiobookSessionManager.swift:321` and the existing tests are the gates.

The OPDS shape matrix is the regression-coverage gate per the ADR's exit criteria; include the explicit PP-4407 fixture and the meta-assertion that a property-check loader would have failed.

Use `scripts/pbxproj_add_swift.rb` to add the 2 new test files to `Palace.xcodeproj` (PalaceTests target).

Validate: `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds; `-scheme Palace-noDRM` succeeds; `test` passes for the full audiobook test surface; `python3 scripts/palace_mutate.py --file Palace/Audiobooks/AudiobookLoader.swift --tests PalaceTests/AudiobookLoaderDispatchTests --diff-only` shows 100% kill rate.

When done, write `.forgeos/swarms/swarm_5c8ddbd5/transcripts/D-LoaderDispatch.md` with: files modified/added, tests added, LOC delta on AudiobookLoader.swift, mutation kill rate result, key decisions, any gaps for integrator (e.g. if `AudiobookSessionManager` actually requires a signature tweak — which should NOT happen but flag if it does).

Do NOT commit. Do NOT push. Stage for the integrator.
