# Contract C — Kill Registry Dual-Write + Enforce allowedTransitions (WS3)

**Status: READY-PENDING-BUNDLE** (app BUILD SUCCEEDED; targeted-test/mutation run
blocked by the pre-existing PalaceTests bundle blocker + disk exhaustion from the
parallel swarm — orchestrator runs my tests + mutation after the bundle repair.)

## Summary

Completed the full registry dual-write kill and transition enforcement in the
mandated 5-step order. `TPPBookState.allowedTransitions` gained the three
legitimate pairs it omitted; `TPPBookRegistry.setState` now enforces the set via
`canTransition` (assert in DEBUG / log in RELEASE, **state still applied**); a
**fed** `registryStatePublisher` (lifecycle) replaces the dead `syncStatePublisher`
gap; all 9 observers across 6 modules migrated to the Combine publishers per the
contract TARGET MAP; the 2 external posters re-pointed to a new
`holdsDidChangePublisher`; and BOTH NotificationCenter posts + the
`.TPPBookRegistryStateDidChange` name declaration were deleted.

## Internal order followed (non-negotiable)

1. **Corrected `allowedTransitions` FIRST** — added `.downloadSuccessful→.downloadNeeded`,
   `.used→.downloadNeeded`, `.holding→.downloading` with inline comments citing
   ReaderService:585 / AudiobookSessionManager:2227 / DiskBudgetManager:168 and
   DownloadQueueOrchestrator:91 via DownloadStartCoordinator:278. The 3 real call
   sites were NOT edited (correcting the SET legalizes them).
2. **Created AND FED `registryStatePublisher`** — `CurrentValueSubject<RegistryState>(.unloaded)`
   fed from the `state` setter on every lifecycle transition (replaces the `:283`
   post). Emits on load-complete, so the empty-registry sign-in path fires.
3. **Enforced at `setState`** via `canTransition`; violation routes through an
   injectable `onIllegalTransition` handler (DEBUG `assertionFailure` / RELEASE
   `Log.error`), then the write is applied unconditionally.
4. **Migrated all 9 observers** + re-pointed the 2 posters (table below).
5. **Deleted both posts LAST** — `postStateNotification` + its 5 call sites, the
   `:283` post, and the `.TPPBookRegistryStateDidChange` name decl (grep-clean of
   all production + test consumers first).

## Observer → publisher migration table (all 9 + 2 posters)

| # | Site | Migrated to | Notes |
|---|------|-------------|-------|
| 1 | CatalogUI/ViewModels/ActiveSessionsViewModel.swift:135 | `bookStatePublisher` | injected `bookRegistry`; per-book refresh |
| 2 | CatalogUI/Views/CatalogLaneMoreView.swift:122 | `bookStatePublisher` (via `appContainer.bookRegistry`) | emits changed id |
| 3 | CatalogUI/Views/CatalogSearchView.swift:112 | `bookStatePublisher` (`AppContainer.production()`) | emits changed id |
| 4 | AppInfrastructure/AppTabHostView.swift:456 (holds badge) | `registryStatePublisher` + `bookStatePublisher` + `holdsDidChangePublisher` | lifecycle + per-book + hand-fired |
| 5 | Book/UI/BookDetail/BookDetailView.swift:134 | `bookStatePublisher` (`viewModel.registry`) | filters to book id |
| 6 | Book/UI/BookDetail/HalfSheetview.swift:227 | `bookStatePublisher` (`bookRegistry`) | filters to book id |
| 7 | MyBooks/MyBooksDownloadCenter.swift:2076 (launch reconcile) | **`registryStatePublisher`** | one-shot `AnyCancellable`; empty-registry hang avoided |
| 8 | MyBooks/MyBooks/MyBooksViewModel.swift:338 | `bookStatePublisher` | merged w/ still-present `.TPPBookRegistryDidChange` + `.TPPSyncEnded` |
| 9 | Book/Models/TPPBookRegistry.swift:455 (SAML sync, `waitForLoadThenRunSync`) | **`registryStatePublisher`** | one-shot sink; empty-registry hang avoided |
| P1 | Holds/HoldsViewModel.swift:249 | `bookRegistry.notifyHoldsChanged()` | poster → holds-changed |
| P2 | Settings/DeveloperSettings/DeveloperSettingsViewModel.swift:741 | `self.bookRegistry.notifyHoldsChanged()` | added `bookRegistry` dep; poster → holds-changed |

## Files changed

**Production (13):** TPPBookState.swift, TPPBookRegistry.swift,
ActiveSessionsViewModel.swift, CatalogLaneMoreView.swift, CatalogSearchView.swift,
AppTabHostView.swift, NSNotification+TPP.swift, BookDetailView.swift,
HalfSheetview.swift, MyBooksViewModel.swift, MyBooksDownloadCenter.swift (**only**
the :2076 observer block + its `reconcileObserver` decl — Contract E's rest of the
file untouched), HoldsViewModel.swift, DeveloperSettingsViewModel.swift.

**Tests/mocks (12):** TPPBookRegistryMock.swift (added the 3 new protocol members +
lifecycle feed in `state` setter), **NEW**
Contract/TPPBookRegistryMutationContractTests.swift, ActiveSessionsViewModelTests.swift
(11 ctor sites + test-6 migrated to `bookStatePublisher`), MyBooksViewModelTests.swift
(state-change test → `bookStatePublisher`), AudiobookTimeEntryTests.swift (dropped the
deleted-name raw-value assertion), ContinueRowSectionTests.swift +
CatalogViewContinueRowsIntegrationTests.swift (ctor arg), and the 4 Reader2/Audiobook
Contract test conformers (forward the 3 new protocol members to `inner`).
pbxproj: registered the new test file via `scripts/pbxproj_add_swift.rb`.

**NOT touched (boundaries honored):** Palace/MyBooks/Sideload/** (Contract D — its
diff is present in the shared worktree but NOT in my staged set), Store.swift /
PalaceAuth Effect.swift (Contract B), the 3 legit-transition call sites, the rest of
MBDC (Contract E).

## New public surface

- `TPPBookState.allowedTransitions` +3 pairs; `canTransition` now live/enforced.
- `TPPBookRegistryProvider` gains `registryStatePublisher`, `holdsDidChangePublisher`,
  `notifyHoldsChanged()` (implemented in `TPPBookRegistry` + `TPPBookRegistryMock` +
  4 inline test conformers).
- `TPPBookRegistry.IllegalTransitionHandler` typealias + `defaultIllegalTransitionHandler`
  + optional `onIllegalTransition:` init param (defaulted; test-injectable).
- `.TPPBookRegistryStateDidChange` removed.

## Tests written (TPPBookRegistryMutationContractTests)

- `testCanTransition_newlyLegalPairs_areAllowed` / `..._illegalPairs_areRejected` —
  pure, kills the dropped-set-entry and constant-true mutants.
- `testSetState_illegalTransition_invokesHandler_andStillApplies` — REAL seam:
  handler fires with exact pair AND state still applied (`.used`).
- `testSetState_legalTransition_doesNotInvokeHandler` — inverted-guard mutant.
- `testSetState_newlyLegalTransitions_doNotInvokeHandler_atRealSeam` — ties Step-1
  to Step-3 through the enforced seam for all 3 pairs.
- `testRegistryStatePublisher_isFed_onStateWrite` — REAL registry via `reset` +
  `dropFirst()`; kills the removed-`.send` mutant.
- **Mandatory guard (b) — empty-registry hang:**
  `testEmptyRegistryLoad_lifecycleObserversFire_withZeroPerBookEmissions` — models
  registry:455 (SAML) + MBDC:2076 (reconcile) predicates on `registryStatePublisher`;
  both fire on a `.loaded` lifecycle emission with **zero** per-book emissions.
- **Badge lifecycle guard (a):**
  `testHoldsBadge_refreshesOnLifecycleSync_withZeroPerBookEmissions` +
  `testHoldsBadge_refreshesOnHoldsChangedTrigger`.
- **Contract snapshot:** `testEnforcedSeam_illegalTransitionSequence_matchesContract`
  — `ContractSnapshot.assert` over the ordered illegal-transition reports across a
  fixed transition walk (the newly-legal step produces NO report; a removed set
  entry or inverted check drifts it).

## DoD evidence

- **App compile (primary TODAY gate): `** BUILD SUCCEEDED **`**
  `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/dd-C-1368 build`
  (only pre-existing Readium SPM dependency-scan warnings).
- **AC grep block: 18/18 explicit ACs PASS + AC7 (6/6 per-book observers) PASS +
  AC11 (my diff does not modify Sideload) PASS.** (The worktree shows Sideload
  dirty — that is Contract D's change, not mine; my staged set excludes it.)
- **Targeted test + `palace_mutate --diff-only`: NOT YET GREEN.** First attempt
  surfaced ONE real error in my test file (a `cancellables` property shadowing the
  one `PalaceWiringTestCase` already provides) — **fixed** (removed the redeclaration,
  use the inherited property). The re-verification run is blocked by (1) the KNOWN
  pre-existing PalaceTests bundle blocker (`RuntimeQuiescenceGateTests.swift`,
  Swift-6 `DispatchSemaphore`) a Fable agent is repairing in parallel, and (2) the
  shared volume hitting 100% (2.3 GiB free) from the parallel swarm's isolated
  derivedData — a full test-bundle compile+link needs more. I did not prune the
  shared DerivedData mid-swarm (would disrupt sibling builds). Per the BUNDLE NOTE,
  the orchestrator runs `-only-testing:PalaceTests/TPPBookRegistryMutationContractTests`
  + diff-scoped mutation on TPPBookRegistry.swift and TPPBookState.swift after the
  bundle repair.

## Notes for the orchestrator

- The contract snapshot self-records its baseline at
  `PalaceTests/Contract/__Snapshots__/TPPBookRegistryMutationContractTests/enforcedSeamIllegalTransitionSequence.json`
  on first run (fails once with "snapshot recorded — re-run to verify"); commit the
  JSON after reviewing the 2-entry diff.
- Everything in my scope is **staged** (25 files incl. pbxproj). Sibling changes
  (Sideload / PalaceAuth / other test files) are left untouched/unstaged by me.
