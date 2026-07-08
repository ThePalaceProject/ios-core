# CatalogUI — swarm_27c181b5 implementer transcript

Status: **READY** (A1/A2/A3/A5 all landed; no scope deferral).

## Summary
- **A1** — Extracted the old `refresh()` body into `private func reload(invalidatingCache:) async`.
  `refresh()` (pull-to-refresh) → `reload(invalidatingCache: true)`; `handleAccountChange()`
  → `reload(invalidatingCache: false)` (serves the account-scoped SWR cache instantly, no invalidate).
  Deleted the `(repository as? CatalogRepository)?` cast — invalidation now routes through the
  PROTOCOL seam `repository.invalidateCache(for:)` (mirrors `forceRefresh()`). Added
  `await AppLaunchTracker.shared.recordMilestone(.catalogLoaded)` on `load()`'s success path.
  `.catalogLoaded` already existed in `LaunchMilestone` — no AppLaunchTracker edit needed.
- **A2** — `CatalogView.switchToAccount`: deleted the redundant `.TPPCurrentAccountDidChange`
  post and the direct `Task { await viewModel.refresh() }`. The `accountsManager.currentAccount`
  setter already posts the notification (AccountsManager.swift:632) → `onReceive` (:58) →
  `handleAccountChange` → SWR reload. Verified the setter behavior read-only.
- **A3** — Deleted `account.loadAuthenticationDocument { _ in }`; the setter's
  `driveCurrentAccountAuthDocIfNeeded()` (AccountsManager.swift:624, single-flighted) covers it.
- **A5** — Removed the three per-body/init `CatalogRepository(api: DefaultCatalogAPI(...))` builds.
  Added ONE shared, lazily-cached `catalogAPI` + `catalogRepository` accessor region to
  `AppContainer` (same lazy+static-cache shape as `ratingPromptPresenter`/`audiobookSessionPresenter`;
  the repository is account-UUID scoped, mirroring AppTabHostView's main catalog repository).
  Did NOT touch the memberwise `init` or `production()` account-hydration. Added
  `import PalaceCatalog` to AppContainer (required for the accessor to compile).

## Files modified
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` — reload/refresh/handleAccountChange + milestone (A1)
- `Palace/CatalogUI/Views/CatalogView.swift` — switchToAccount cleanup (A2/A3)
- `Palace/CatalogUI/Views/CatalogLaneMoreView.swift` — inject `appContainer.catalogRepository` (searchSection) + `appContainer.catalogAPI` (VM init) (A5)
- `Palace/CatalogUI/Views/CatalogSearchView.swift` — 2nd init uses `AppContainer.production().catalogRepository` (A5)
- `Palace/CatalogUI/ViewModels/CatalogLaneMoreViewModel.swift` — `api` fallback → `AppContainer.production().catalogAPI` (A5)
- `Palace/AppInfrastructure/AppContainer.swift` — NEW shared catalog accessor region + `import PalaceCatalog` (A5)
- `PalaceTests/CatalogUI/CatalogViewModelTests.swift` — 3 new tests + 2 helpers
- `PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift` — extended the inline `CatalogRepositoryMock` (invalidate tracking + cache simulation)

Production LOC net is small; the `_catalogRepository`/`_catalogAPI` accessor is the largest single add.

## Tests added (PalaceTests/CatalogUI/CatalogViewModelTests.swift, class CatalogViewModelStateMachineTests)
- `testHandleAccountChange_servesCache_doesNotInvalidate` — asserts `invalidateCacheCallCount == 0`
  and state → `.loaded` after an account change (via the production `handleAccountChange` seam).
- `testRefresh_pullToRefresh_invalidatesOnce` — asserts `invalidateCacheCallCount == 1` and
  `lastInvalidatedURL == testURL`.
- `testSwitchBackAndForth_ABA_servesCacheNotThreeFetches` — drives `load(A)` → `handleAccountChange(B)`
  → `handleAccountChange(A)` through the production seam with a cache-simulating mock; asserts A's
  per-URL network-fetch count stays at 1 on return and `invalidateCacheCallCount == 0` across all legs.

Mock extension: the inline `CatalogRepositoryMock` gained `invalidateCacheCallCount`,
`lastInvalidatedURL`, `loadHistory`, and a `simulatesCache` per-URL cache model
(`networkFetchCount(for:)` counts cache misses; `invalidateCache` evicts). Conformance switched to
`@preconcurrency CatalogRepositoryProtocol` so `invalidateCache`/`cachedFeed` can be `@MainActor`
witnesses that mutate/read tracking state (matches the sibling shared `CatalogRepositoryTestMock`).

## Verification criteria (grep outputs)
```
V1  grep -c 'as? CatalogRepository' …CatalogViewModel.swift            → 0   ✅
V2  grep -c 'func reload(invalidatingCache' …CatalogViewModel.swift     → 1   ✅
    reload(invalidatingCache: false)                                    → 1  (≥1) ✅
    reload(invalidatingCache: true)                                     → 1  (≥1) ✅
V3  grep -c 'loadAuthenticationDocument' …CatalogView.swift             → 0   ✅
    switchToAccount: no .TPPCurrentAccountDidChange post, no viewModel.refresh()  ✅
    (remaining .TPPCurrentAccountDidChange is the onReceive publisher at :58; the
     two viewModel.refresh() at :186/:202 are pull-to-refresh handlers — correct)
V4  grep -c 'recordMilestone(.catalogLoaded)' …CatalogViewModel.swift   → 1   ✅
V5  grep -c 'CatalogViewModel(' …CatalogViewModelTests.swift            → 3   ✅
V6  python3 scripts/check-test-name-vs-body.py …CatalogViewModelTests.swift
    → OK: 1 file(s) checked, 0 fake-wiring tests found.  exit=0         ✅
```

## Definition-of-Done evidence
1. **SUT instantiation** — `grep -c 'CatalogViewModel(' …CatalogViewModelTests.swift` → 3 (≥1). ✅
2. **Function-result usage** — `reload(...)`/`invalidateCache(...)` are `Void`; `recordMilestone` is
   fire-and-forget analytics (`await`ed, no result). No discarded meaningful results. ✅
3. **Multi-step test body** — `testSwitchBackAndForth_ABA_…` literally drives all three legs
   (load A, switch→B, switch→A) with a per-leg `await waitUntilLoaded(...)` — no commented steps. ✅
   (name has no `across/twice/reset/retry/again/roundtrip/viaX` trigger token.)
4. **Scope audit** — A1, A2, A3, A5 all in diff. No deferral. ✅
5. **Mutation** — CatalogUI is NOT a mutation-strict critical path (not Audiobooks/SignInLogic/
   MyBooks/Download*/PalaceAuth). Behavioral kill coverage: flipping `handleAccountChange` to
   `invalidatingCache: true` fails both test 1 (`invalidateCacheCallCount` 0→1) and test 3
   (A refetched → count 2); removing the `refresh()` invalidate fails test 2. Left to the
   orchestrator's consolidated `--diff-only` run if desired.
6. **Build + verify-pr** — deferred to the orchestrator's consolidated build per swarm rules
   (I did not run a full app build or git). All edits mirror existing compiling call sites
   (OPDS2 feed builder = OPDS2CatalogWiringTests helpers; DefaultCatalogAPI build = AppTabHostView;
   `@preconcurrency` mock = CatalogRepositoryTestMock).
7. **Wiring-claim coverage** — test 3's cited production seam (`handleAccountChange` → `reload` →
   `load`) is genuinely driven; `activeEntryPointURL` (set only on load success) is the completion
   gate, so a non-loading leg cannot satisfy `waitUntilLoaded`.
8. **Contract reconciliation** — run by orchestrator at commit time against the commit body.
9. **Blast-radius** — `python3 scripts/check-blast-radius.py --quiet` → exit 0. ✅
10. **Adjacency-staleness** — `python3 scripts/check-adjacency-staleness.py --quiet` → exit 0. ✅
11. **Superpartner-spectrum** — `python3 scripts/check-superpartner-spectrum.py --quiet` → exit 0. ✅

## A5 scope-deferral
None. A5 was a clean injection — the target views already carried an `AppContainer`
(`CatalogLaneMoreView`) or already used `AppContainer.production()` (`CatalogSearchView` 2nd init;
`CatalogLaneMoreViewModel` default), so no per-account config entanglement. AppTabHostView's main
catalog repository was left as-is (out of edit scope); the shared accessor serves only the three
secondary sites — still the "one instance, not one-per-render" win.

## Notes / assumptions
- `import PalaceCatalog` added to AppContainer.swift — necessary for the A5 accessor
  (`DefaultCatalogAPI`/`CatalogRepository`/`CatalogRepositoryProtocol`/`OPDSParser`). Treated as
  part of the A5 shared-instance region.
- The shared `catalogRepository` is a SEPARATE instance from AppTabHostView's main-VM repository
  (that file is out of scope); both are account-UUID scoped so they key identically but hold
  independent in-memory caches. Consolidating them is a possible follow-up, not required by the contract.
