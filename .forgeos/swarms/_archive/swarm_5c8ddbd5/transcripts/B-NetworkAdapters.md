---
name: swarm_5c8ddbd5-transcript-B-NetworkAdapters
type: ephemeral
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: 180d
owners: [network]
description: Module B transcript — Network Adapters
---

# Module B transcript — Network Adapters

**Swarm:** `swarm_5c8ddbd5` (Audiobook Vendor Adapter Extraction)
**Module:** B — OpenAccess + BearerToken + LocalFile adapters
**Date:** 2026-05-21
**Base:** Module A protocol committed at `03055f21d`; baseline build fix at `40a5f57da`
**Status:** Complete — staged for integrator (NOT committed, NOT pushed per swarm protocol)

## Files added (6)

### Production (3)
| File | LOC | Notes |
|---|---|---|
| `Palace/Audiobooks/Vendors/OpenAccessAdapter.swift` | 108 | Open-access network manifest fetch |
| `Palace/Audiobooks/Vendors/BearerTokenAdapter.swift` | 138 | Two-step CM fulfill flow (wrapper → real manifest) |
| `Palace/Audiobooks/Vendors/LocalFileAdapter.swift` | 127 | On-disk manifest read + optional bearer-token refresh |

All under the 200-LOC budget. Each adapter is `final class`, non-`@MainActor`-isolated (the `AudiobookVendorAdapter` protocol is not `@MainActor`; main-thread hops happen inside callbacks).

### Tests (3)
| File | Tests | Notes |
|---|---|---|
| `PalaceTests/Audiobook/Vendors/OpenAccessAdapterTests.swift` | 6 | Contract-named cases |
| `PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift` | 5 | 4 contract-named + 1 added for `canHandle` mutation kill |
| `PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift` | 6 | Contract-named cases |

**17 test cases total. All pass in 0.6s.**

## Test names (17)

### OpenAccessAdapterTests (6)
1. `testCanHandle_anyOPDSBook_returnsTrueAsFallback` — pins `canHandle` returning true as the chain's fallback
2. `testResolveManifest_successPath_completesWithJSON` — JSON dict propagates verbatim
3. `testResolveManifest_networkError_failsWithManifestFetchFailed` — network error mapping
4. `testResolveManifest_emptyData_failsWithManifestFetchFailed` — empty-data short-circuit
5. `testResolveManifest_htmlResponse_failsWithManifestFetchFailed` — login-redirect HTML → fetchFailed (not parseFailed)
6. `testResolveManifest_invalidJSON_failsWithManifestParseFailed` — non-dict JSON → parseFailed

### BearerTokenAdapterTests (5)
1. `testCanHandle_anyBookWithAcquisition_returnsTrue` — **added** for `canHandle` mutation kill (contract requires 100% kill rate; without this the `return true` mutant survived)
2. `testResolveManifest_detectsBearerTokenInResponse_recursesToLocationURL` — wrapper detection triggers second-leg fetch
3. `testResolveManifest_bearerTokenFetchSuccess_completesWithRealManifest` — second-leg payload propagates to caller
4. `testResolveManifest_bearerTokenFetchFails_failsWithManifestFetchFailed` — second-leg nil → fetchFailed
5. `testResolveManifest_setsBookBearerTokenSideEffect` — verifies `book.bearerToken` / `book.bearerTokenFulfillURL` mutation (Keychain-guarded)

### LocalFileAdapterTests (6)
1. `testCanHandle_localFileExists_returnsTrue` — happy-path can-handle
2. `testCanHandle_noLocalFile_returnsFalse` — both nil-URL and missing-file failure modes
3. `testResolveManifest_validJSON_succeeds` — disk JSON propagates verbatim
4. `testResolveManifest_unreadableFile_failsWithManifestParseFailed` — thrown reader error mapping
5. `testResolveManifest_bearerTokenFulfillURL_refreshesTokenBeforeReturn` — refresh-then-complete path (Keychain-guarded)
6. `testResolveManifest_noBearerTokenFulfillURL_skipsRefresh` — skip-refresh path (companion to #5 — pins TRUE/FALSE bifurcation)

## Validation

| Check | Result |
|---|---|
| `xcodebuild ... -scheme Palace build` | **BUILD SUCCEEDED** |
| `xcodebuild ... -scheme Palace-noDRM build` | **BUILD SUCCEEDED** |
| `xcodebuild ... test -only-testing:OpenAccessAdapterTests,BearerTokenAdapterTests,LocalFileAdapterTests` | **17/17 PASS** in 0.581s |
| Mutation: OpenAccessAdapter | **1/1 killed (100%)** |
| Mutation: BearerTokenAdapter | **1/1 killed (100%)** after adding `testCanHandle_anyBookWithAcquisition_returnsTrue` |
| Mutation: LocalFileAdapter | **1/1 killed (100%)** |

`--diff-only` against `origin/develop` reports zero changed lines because these are new files; the absolute-line mutation runs (above) are what gate the contract. Mutation engine's log-line filter is in effect — most candidate mutation points were inside `Log.debug/info/error` calls and skipped.

## Mutation kill rates

| Adapter | Killed | Survived | Kill rate |
|---|---|---|---|
| OpenAccessAdapter | 1 | 0 | **100.0%** |
| BearerTokenAdapter | 1 | 0 | **100.0%** |
| LocalFileAdapter | 1 | 0 | **100.0%** |

Cache files:
- `.forgeos/mutation-cache/OpenAccessAdapter.5230d1cd7d62bc5d.json`
- `.forgeos/mutation-cache/BearerTokenAdapter.7a94cf8747296a24.json`
- `.forgeos/mutation-cache/LocalFileAdapter.80e611d72b123ffc.json`

## Key decisions

1. **Adapter-local collaborator protocols.** Per the contract's "constructor-style DI / zero AppContainer reads" rule, each adapter defines a narrow protocol for its collaborators:
   - `AudiobookManifestNetworkFetching` (shared by OpenAccess + BearerToken) — single `fetchData(from:completion:)` shape that wraps `TPPNetworkExecutor.GET(_:completion:)`. Production conformance lives in Module D's loader-wiring change (not in this module per the don't-touch rule on AudiobookLoader.swift).
   - `BearerTokenManifestFetching` (BearerToken only) — wraps `BookService.fetchManifestWithBearerToken`. Lets tests stub the second-leg recursion.
   - `AudiobookFileReading` (LocalFile only) — `fileExists(atPath:)` + `data(at:)`. Tests inject an in-memory fake.
   - `BearerTokenRefreshing` (LocalFile only) — wraps `MyBooksSimplifiedBearerToken.refreshToken`. Lets tests drive both refresh-success and refresh-failure branches.
   - `MyBooksDownloadCenterProviding` — **reused** from `Palace/MyBooks/MyBooksDownloadCenterProtocol.swift` (already on develop); LocalFileAdapter consumes it via the existing seam.
2. **Failure-mode refinement.** The pre-swarm `fetchOpenAccessManifest` lumped every failure into a single `nil` completion that the caller mapped to `.manifestFetchFailed`. The contract's test names require distinguishing fetch-vs-parse failures, so adapters now map HTML responses + network errors + empty data → `.manifestFetchFailed`, and non-dict JSON → `.manifestParseFailed`. This is a refinement, not a regression; downstream error handling already accepts both cases.
3. **OpenAccessAdapter does NOT do bearer-token detection.** Per the contract, that branch was carved into BearerTokenAdapter exclusively. OpenAccess is the simple network adapter; BearerToken is the recursive two-leg adapter. Both have the same first-leg fetch logic; BearerToken adds bearer-token JSON inspection + recursion.
4. **BearerTokenAdapter's `canHandle` returns true.** The dispatch decision (when to invoke BearerToken vs OpenAccess) lives in Module D's loader rewrite. Module B's BearerTokenAdapter can drive any book; Module D's chain decides when.
5. **Non-MainActor adapters.** The `AudiobookVendorAdapter` protocol from Module A is not `@MainActor`-isolated (it ships with main-thread-completion as a doc-comment contract, not a compiler-enforced isolation). Initially I `@MainActor`-isolated the adapter classes; that produced "conformance crosses into main actor-isolated code" Swift 6 warnings. Dropping the class-level `@MainActor` and using `Task { @MainActor in ... }` inside callbacks (matching the existing `AudiobookLoader.swift` pattern) is the clean fix.
6. **Added one test beyond contract count.** Contract specified 4 BearerTokenAdapter tests; I added `testCanHandle_anyBookWithAcquisition_returnsTrue` (5 total) because without it the mutation kill rate on `canHandle`'s `return true` was 0%. The acceptance criteria require 100% kill rate; the test count is a floor, not a ceiling.

## Gaps for integrator

1. **`pbxproj` is co-staged with Module C's changes.** The `Palace.xcodeproj/project.pbxproj` file in the staged set contains both my 6 new file references (OpenAccess/BearerToken/LocalFile + their tests) AND Module C's 3 entries (LCPAdapter.swift, LCPAdapterTests.swift, LCPAcquisitionPredicateTests.swift) — Module C had already landed its files in the worktree before Module B started, so `pbxproj_add_swift.rb` saw them as part of the working state. The integrator's job is to reconcile when both modules commit. **Recommendation:** integrator commits both modules' pbxproj entries together as part of the swarm integration commit.

2. **Module C's `LCPAdapter.swift` has a separate `TPPNetworkExecutor` conformance issue** (`LCPAdapter.swift:54 error: type 'TPPNetworkExecutor' does not conform to protocol 'LCPAdapterNetworkExecutor'`) that I observed on first build. The build later succeeded — appears to be a transient build-order issue. Both `-scheme Palace` and `-scheme Palace-noDRM` build clean at present. Module C's implementer or the integrator should verify the LCPAdapter signature mismatch is resolved before merging.

3. **Module D will need to wire production conformances.** None of these protocols have production conformances yet — Module D's loader-dispatch rewrite is the natural home:
   - `AudiobookManifestNetworkFetching` ← extend `TPPNetworkExecutor`
   - `BearerTokenManifestFetching` ← thin wrapper around `BookService.fetchManifestWithBearerToken`
   - `AudiobookFileReading` ← thin wrapper around `FileManager.default` + `Data(contentsOf:)`
   - `BearerTokenRefreshing` ← thin wrapper around `MyBooksSimplifiedBearerToken.refreshToken`
   - The wrapper classes can live in a single `Palace/Audiobooks/Vendors/AdapterProductionAdapters.swift` or be inline in Module D's loader rewrite.

4. **Two side-effect tests are Keychain-guarded.** `testResolveManifest_setsBookBearerTokenSideEffect` (BearerTokenAdapter) and `testResolveManifest_bearerTokenFulfillURL_refreshesTokenBeforeReturn` (LocalFileAdapter) call `KeychainAvailability.skipIfUnavailable()` because they write `book.bearerToken` / `book.bearerTokenFulfillURL` which round-trip through `TPPKeychainVariable`. They pass locally; on CI hosts without Keychain entitlement they skip cleanly per the established convention.

5. **The pre-swarm log-line filter in `palace_mutate.py` collapses our effective mutation surface.** All three adapters surfaced exactly 1 real mutation point each (the `canHandle` return value) — everything else was inside `Log.*` calls and got skipped per the engine's documented rule. The 100% kill rate is honest but reflects a small mutation surface; Module D's end-to-end matrix tests are what will pin the heavier behavior carve-out.

6. **AudiobookLoader.swift is unchanged.** Per the don't-touch rule, the loader's pre-swarm code at lines 142-219 (resolveManifestAndDecryptor) and 346-396 (fetchOpenAccessManifest) is still present and still in production. Module D's rewrite will swap it out for the adapter chain.

## Files staged for integrator

```
A  Palace/Audiobooks/Vendors/BearerTokenAdapter.swift
A  Palace/Audiobooks/Vendors/LocalFileAdapter.swift
A  Palace/Audiobooks/Vendors/OpenAccessAdapter.swift
A  PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift
A  PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift
A  PalaceTests/Audiobook/Vendors/OpenAccessAdapterTests.swift
M  Palace.xcodeproj/project.pbxproj    (co-staged with Module C — see gap #1)
```

No commits made. No pushes made. Integrator owns the commit per swarm protocol.
