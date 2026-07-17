# Architect re-review — Contract C (AMENDED) — swarm_8ce6f5ae

verdict: BLOCKED

Reviewer: architect-reviewer (Fable), re-review of the amended
`contracts/C-Registry-DualWrite.md` + manifest C block, 2026-07-17.
Scope: the 3 amendment corrections only. Full repo grepped under
`$WT/Palace/`.

---

## Check 1 — Transition-set completeness: FAIL (one live transition still missing)

Method: enumerated EVERY production `setState(...)` call site (grep across
`Palace/**/*.swift|*.m|*.h`, excluding tests) and resolved the from-state for
each. Enforcement surface note: `addBook` / `updateBook` / `updateAndRemoveBook`
mutate state WITHOUT calling `setState` (they post + `bookStateSubject.send`
directly — `TPPBookRegistry.swift:528-564,578-590,592-603`), so enforcement at
`setState:605` never sees them. Good: narrower surface, and it makes
`BorrowOperation.swift:455` safe — `addBook(state: mapping.state)` is issued
first through the barrier-serialized `BookRegistryStore` (`performBarrier`,
`BookRegistryStore.swift:184-206`), so the immediately-following
`setState(mapping.state)` reads previousState == mapping.state → self-transition
(always allowed). `mapping.state` ∈ {.downloadNeeded, .holding} only
(`BorrowOperation.swift:188-220`).

Audit of all setState targets vs. the CORRECTED set (current set at
`TPPBookState.swift:91-133` + the 2 amendment pairs):

| target | from-states observed | in corrected set? |
|---|---|---|
| .downloadNeeded | .downloadSuccessful (ReaderService:585, AudiobookSessionManager:2227, DiskBudgetManager:168) → **amendment pair, OK**; .used (same 3) → **amendment pair, OK**; .downloading/.SAMLStarted/.downloadFailed (MBDC:1254, DownloadAuthRetryHandler:347/386/417/452, DownloadCancellationHandler:94/125, BookSignInRedirectHandler:99/145/225, AdobeDRMHandler:142, TokenRefreshInterceptor ×7) | yes |
| .downloading | .downloadNeeded/.downloadFailed/.SAMLStarted/.unregistered — yes; **`.holding` — NO. MISSING.** | **NO** |
| .downloadSuccessful | .downloading (MBDC:1146 markDownloadSuccessful via AdobeDRMHandler:132 + LCPFulfillmentHandler:188/204; BackgroundDownloadHandler:300/347/351) | yes |
| .downloadFailed | .downloading/.downloadNeeded/.SAMLStarted (MBDC:1482, RightsManagementDispatcher:161, BookSignInRedirectHandler:171, TokenRefreshInterceptor:381); MBDC:2147 `.markFailed` is a self-transition — `DownloadTaskPersistence.swift:92-94` only returns `.markFailed` when registry is ALREADY `.downloadFailed` | yes |
| .SAMLStarted | .downloadNeeded/.downloading (MBDC:1245 logInvalidURLRequest fires mid-download; retry handlers fire from .downloading) | yes |
| .used | .downloadSuccessful (TPPPDFDocumentMetadata:82; PDF open requires downloadSuccessful) | yes |
| .unregistered | all states (BookReturnService ×5, DownloadStartDispatcher:255/262, DownloadAuthRetryHandler:470, TokenRefreshInterceptor:252, MyBooksViewModel:183, TPPBookRegistryAsync:130) — set has X→.unregistered for every state | yes |
| .holding | only via BorrowOperation:455 → self-transition (see above) | yes |

### F1 (BLOCKING) — `.holding → .downloading` is live and NOT in the corrected set

Concrete path, every hop grep-verified:

1. A ready hold is `.holding` in the registry — `BookRegistryStore.updateBook`
   maps availability ready/reserved → `.holding`
   (`BookRegistryStore.swift:218-230`).
2. Ready hold renders the Get button — `BookButtonMapper.swift:54-57`
   (`.holding` + `TPPOPDSAcquisitionAvailabilityReady` → `.canBorrow`).
3. `.get` action funnels straight into download —
   `BookCellModel.swift:554-563` (`case .download, .retry, .get:` →
   `didSelectDownload()`) → `startDownloadNow()` →
   `downloadCenter.startDownload(for: book)` (`BookCellModel.swift:745`).
4. `DownloadStartCoordinator.startDownloadAsync` EXPLICITLY lets `.holding`
   proceed — `DownloadStartCoordinator.swift:278`
   (`case .downloadFailed, .downloadNeeded, .holding, .SAMLStarted: break`).
5. If the concurrent-download cap is hit (`!canStart`,
   `DownloadStartCoordinator.swift:289-293`) →
   `queueOrchestrator.enqueuePending(book)` →
   `bookRegistry.setState(.downloading, for:)` —
   `DownloadQueueOrchestrator.swift:91`, with the from-state still `.holding`.
   (This setState-first is a deliberate UX fix — the doc comment at
   `DownloadQueueOrchestrator.swift:83-90` says so.)

Result: patron with cap-saturated downloads taps Get on a ready hold →
`.holding → .downloading` → `canTransition` false → DEBUG `assertionFailure`
→ dev-build crash / Monday DEBUG-suite red. Same class of bug the first BLOCK
caught; the amendment fixed 2 of 3 missing pairs.

(If the cap is NOT hit, the direct path routes `.holding` → `startBorrow` at
`DownloadStartDispatcher.swift:205-206` — safe. Only the enqueue branch trips.)

Watch-item (non-blocking): `.downloadFailed → .downloadSuccessful` is
unreachable by my reading — `.markFailed` requires a dead task
(`DownloadTaskPersistence.swift:75-94`) and dead tasks deliver no completion;
still-live tasks are `.adopt`ed. No pair needed.

## Check 2 — RegistryState publisher + per-observer target map: ONE UNDER-ROUTE (blocking)

Verified good:
- `syncStatePublisher` IS dead: `syncStateSubject` declared
  `TPPBookRegistry.swift:301`, publisher accessor `:303-304`, protocol `:18` —
  grep finds ZERO `.send` into it anywhere. Amendment claim (b) correct.
- `:283` IS the registry-LIFECYCLE signal: it is the side effect of the
  `RegistryState` setter (`TPPBookRegistry.swift:272-286`). A new FED
  RegistryState publisher is the right home. Correct.
- Observer census: exactly 9 observers + 2 hand-posters + the name decls in
  `NSNotification+TPP.swift:26,54` — full-repo grep (incl. `*.m`/`*.h`) matches
  the contract's list 1:1. No stragglers. Correct.
- #9 `TPPBookRegistry:455` (`waitForLoadThenRunSync`) gates on
  `state == .loaded || .synced` (`:464`) — pure lifecycle; empty-registry
  sign-in emits zero per-book events → RegistryState publisher routing is
  CORRECT (bookStatePublisher would hang).
- #7 `MyBooksDownloadCenter:2076` — one-shot wait-for-registry-load before
  launch reconciliation (`:2069-2076`) — same shape, RegistryState routing
  CORRECT.
- The 6 per-book observers → `bookStatePublisher`: correct for their state
  refresh purpose.

### F2 (BLOCKING) — Observer #4 (AppTabHostView:456 holds badge) is under-routed; loses its sync-complete trigger

The contract routes #4 to `bookStatePublisher + holdsDidChangePublisher`. That
drops the trigger the badge actually depends on:

- The badge is **availability-driven**, not state-driven:
  `updateHoldsBadge` computes `readyCount` from
  `defaultAcquisition.availability` ready-vs-reserved
  (`AppTabHostView.swift:544-586`), and its guard `shouldUpdateBadge`
  (`:527-529`) keys on **`TPPBookRegistry.RegistryState` == .loaded/.synced** —
  this observer is itself lifecycle-shaped.
- A background loans sync that flips a hold reserved→ready does NOT change
  `TPPBookState` (stays `.holding`), and `updateBook` suppresses emission when
  state is unchanged — `if nextState != previousState` at
  `TPPBookRegistry.swift:583` → **no `bookStateSubject` event**.
- `holdsDidChangePublisher` fires only from the 2 hand-post sites
  (HoldsViewModel:249 user actions, DeveloperSettings:741) — not from sync.
- Today that case is covered by the `:283` lifecycle post on sync completion.
  Under the contract's routing, nothing fires → stale in-app holds badge AND
  stale `UIApplication.shared.applicationIconBadgeNumber` (`:583-585`) after
  the exact event the badge exists for (your hold became ready).

Fix is one row in the target map: #4 must ALSO subscribe to the RegistryState
publisher (its own `.loaded/.synced` guard already dedups noise). Keep
bookStatePublisher (catches .holding→.unregistered returns from BookDetail) +
holdsDidChange (immediate refresh on user cancel/place-hold).

Non-blocking note, same mechanism: BookDetailView:134 / HalfSheetview:227 lose
availability-only refreshes (e.g. hold-position updates while state stays
`.holding`) under pure bookStatePublisher routing. Lower stakes; implementer may
optionally add the RegistryState publisher there too. Not required for approval.

## Check 3 — AC9 empty-registry hang guard: ADEQUATE (with one orchestrator note)

The Test contracts section (b) specifies the right scenario: FRESH
EMPTY-REGISTRY load, assert the SAML-sync observer (:455) AND the
launch-reconciliation observer (MBDC :2076) fire via the RegistryState
publisher with ZERO per-book emissions. If either observer were mis-migrated to
`bookStatePublisher`, an empty registry emits no per-book events → the observer
never fires → the test fails. That is exactly the hang scenario, asserted at
observer level (not publisher level). PASS.

Caveat for the Phase-4.5 orchestrator: AC9 as WRITTEN is only a name-grep
(`grep -Eiq 'emptyRegistry|freshSignIn|...'`) — it proves a test exists with a
matching name, not that it drives the observers. At verification time, read the
test body and confirm it (a) loads an empty registry, (b) asserts both observer
callbacks fired, (c) asserts zero bookStatePublisher emissions. The contract's
prose requires this; the grep alone does not enforce it.

---

## recommended_decision:

Amend Contract C in two places (no production call-site edits; both are
contract-text/set changes consistent with the amendment's own approach):

1. In the step-1 set correction (`TPPBookState.swift:91`), add a THIRD pair:
   `.init(from: .holding, to: .downloading)` with inline comment
   `// Ready hold + concurrent-download cap: enqueuePending sets .downloading
   before borrow resolves — DownloadQueueOrchestrator.swift:91 via
   DownloadStartCoordinator.swift:278 (.holding proceeds to download path)`.
   Add it to the AC0 grep and to test-contract (a) (three newly-legal
   transitions, not two).
2. In the per-observer target map, change row #4 (AppTabHostView:456) from
   `bookStatePublisher + holds-changed trigger` to
   `RegistryState publisher + bookStatePublisher + holds-changed trigger`, with
   rationale: the badge is availability-driven and gated on
   RegistryState .loaded/.synced (AppTabHostView.swift:527-529); a sync flipping
   a hold reserved→ready changes NO book state
   (TPPBookRegistry.swift:583 suppresses emission) so only the lifecycle
   publisher covers it. Extend AC8's grep to also require
   `registryStatePublisher|syncStatePublisher` in
   `Palace/AppInfrastructure/AppTabHostView.swift`, and add a test-contract
   line: badge observer fires on a sync-complete lifecycle emission with zero
   per-book emissions.

With those two amendments applied, Contract C is APPROVED for dispatch — all
other transitions audited clean, the dead-publisher analysis is correct, #7/#9
routing is correct, and the AC9 guard genuinely exercises the hang.
