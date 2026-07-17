# Phase-1a Architect Review — swarm_8ce6f5ae

verdict: BLOCKED

Reviewer: ARCHITECT-REVIEWER (Phase 1a, non-skippable — 4/6 contracts critical_path)
Date: 2026-07-17
Basis: every claim below re-verified against live source in this worktree (grep evidence inline).

Blocked on findings 1–3. Findings 4+ are required amendments / advisories that do not
independently block. Checks 4 (E2 extractability) and 5 (no file collisions) PASS.

---

## FINDING 1 (BLOCK — Check 2): allowedTransitions enforcement WILL fire on live, working production flows, and the contract's seed source cannot fix it

Contract C step 1 wires `canTransition` into `setState` with **assertionFailure in
DEBUG** and says to expand `allowedTransitions` "to cover every transition the
Contract-E green snapshots exercise." That seed source is structurally insufficient:
the violating flows live in files **outside Contract E's scope entirely**
(AppInfrastructure, Audiobooks, DiskBudgetManager), so E's snapshots can never
surface them. Enumerated production `setState` call sites (full list audited via
`grep -rn "\.setState(" Palace --include='*.swift'`, ~60 sites) cross-checked
against `TPPBookState.allowedTransitions` (TPPBookState.swift:91–133):

**Confirmed illegal-per-table transitions on live paths:**

1. `.downloadSuccessful → .downloadNeeded` — NOT in the allowed set (from
   `.downloadSuccessful` only `used/returning/unregistered` are allowed). Three
   independent live call sites:
   - `Palace/AppInfrastructure/ReaderService.swift:585` —
     `attemptRedownloadAndReopen`: content-protection transparent re-download
     explicitly "resets the book state to `.downloadNeeded`" on a downloaded book.
   - `Palace/Audiobooks/AudiobookSessionManager.swift:2227` — PP-4800 OverDrive
     expired-URL recovery; the doc comment says it outright: "The download center
     refuses a start for a `.downloadSuccessful` book … so reset to
     `.downloadNeeded` first."
   - `Palace/MyBooks/DiskBudgetManager.swift:168` — LRU eviction removes the file
     of a downloaded book and "registry flipped to .downloadNeeded".
2. `.used → .downloadNeeded` — also NOT allowed (from `.used` only
   `downloadSuccessful/returning/unregistered`). Same three sites hit it whenever
   the book has been opened (e.g. `TPPPDFDocumentMetadata.swift:82` sets `.used`
   on open; ReaderService's redownload fires from the open path; DiskBudget can
   evict a `.used` book's file).

**Consequence as specified:** DEBUG `assertionFailure` fires on OverDrive -1008
recovery, content-protection re-download, and disk eviction — crashing dev builds
and any test that exercises these paths in the Monday full suite (tests run DEBUG).
This is a latent regression baked into the contract, and the contract's own
mitigation ("seed from E snapshots") cannot see it.

Auth-retry paths were checked and are NOT violations: `MyBooksDownloadCenter.swift:1469`
invokes `authRetryHandler.handleAuthFailureIfApplicable` and `guard !handled else
{ return }` **before** the `.downloadFailed` write at :1482, so
`DownloadAuthRetryHandler`/`TokenRefreshInterceptor` retries transition from
`.downloading` (`.downloading → .SAMLStarted/.downloadNeeded` are both allowed).
Log-only-in-RELEASE / assert-in-DEBUG is what the contract specifies (C:44–46,
plan risk #3) — verified — but the DEBUG assert is exactly what reddens the board.

**Required amendment:** seed `allowedTransitions` expansion from THIS call-site
audit, not (only) E snapshots — at minimum add
`(.downloadSuccessful → .downloadNeeded)` and `(.used → .downloadNeeded)` with a
comment naming the redownload/eviction/refulfillment flows; and require the C
implementer to re-run the full `setState` call-site audit before enabling the assert.

---

## FINDING 2 (BLOCK — Checks 1+2): the notification is DUAL-SEMANTIC; "migrate all 9 observers to bookStatePublisher" breaks at least 3 of them, and the contract's "Combine replacements already exist" premise is partly false

`.TPPBookRegistryStateDidChange` carries TWO distinct semantics:

- **Per-book state** — posted by `postStateNotification` (TPPBookRegistry.swift:639,
  with `bookIdentifier`/`state` userInfo). `bookStatePublisher` replaces THIS one.
- **RegistryState (load/sync lifecycle)** — posted by the `state: RegistryState`
  setter at **:283** (no userInfo) on every `.unloaded/.loading/.loaded/.syncing/.synced`
  change. **NO Combine publisher exists for this semantic.** `syncStatePublisher`
  (cited by the contract as an existing replacement) is DEAD: `syncStateSubject`
  is declared at :301 and erased at :304 but **never receives a `.send` anywhere**
  (`grep -rn "syncStateSubject" Palace` → decl + eraseTo only). It has never emitted.

Observers that depend on the RegistryState semantic and would break or degrade if
migrated to `bookStatePublisher` as the contract instructs:

1. **TPPBookRegistry.swift:455 self-observer** (`waitForLoadThenRunSync`) — waits
   for `state == .loaded || .synced` to run the post-sign-in sync (the SAML
   re-auth path, per the :406–424 comment). A plain `load()` of an **empty**
   registry (fresh sign-in, zero loans — the exact SAML-re-auth scenario) emits
   ZERO `bookStateSubject` events (`BookRegistrySync.swift:323–327` sends per-book
   only for books present), so a `bookStatePublisher` one-shot **hangs forever**
   and the shelf never syncs. The contract says "re-point to the internal Combine
   path" — that path does not exist and must be CREATED (a fed
   `registryStatePublisher`); the contract nowhere says to create it.
2. **MyBooksDownloadCenter.swift:2076 one-shot** (`scheduleReconcileDownloadsAtLaunch`)
   — same gate (`isRegistryLoadedForReconcile` = RegistryState `.loaded/.synced`).
   Empty-registry launch → zero per-book emissions → launch download
   reconciliation silently never runs.
3. **AppTabHostView.swift:456** (`updateHoldsBadge`) — its trigger is fed by the
   two external hand-posts whose entire purpose is the badge:
   `HoldsViewModel.swift:249` ("Badge update — centrally managed by
   AppTabHostView") and `DeveloperSettingsViewModel.swift:741` (test-holds
   toggle). C step 3 re-points/drops those posts; unless the badge observer's
   replacement signal is explicitly specified (registryPublisher merge or a
   registry method), holds-badge updates break.
4. (Degraded, not broken) `ActiveSessionsViewModel:135`, `CatalogSearchView:112`,
   `CatalogLaneMoreView:122`, `MyBooksViewModel:338` currently also refresh on the
   :283 registry-level posts (ActiveSessionsViewModel's own comment calls it "the
   startup registry-state burst"). On an empty/no-book-change load,
   `bookStatePublisher` emits nothing; `registryPublisher` DOES emit on every load
   (`registrySubject.send(snapshot)` even when empty) and is the correct target
   for the "refresh on registry activity" semantic. MyBooksViewModel:338 has
   partial redundancy (already merges `.TPPBookRegistryDidChange` + `.TPPSyncEnded`).

**Required amendment to C:** (a) add "create and feed a RegistryState Combine
publisher from the `state` setter (:272–286)" as an explicit step-0 deliverable;
(b) replace the blanket "migrate ALL 9 to bookStatePublisher" with a per-observer
target map (bookStatePublisher vs registryPublisher vs new registryStatePublisher,
merge where needed); (c) name the badge-path replacement for :249/:741; (d) add a
behavioral test for the empty-registry load case on both one-shot observers
(sign-in-with-zero-loans sync + launch reconcile). Without these, deleting the
:283 post regresses two critical paths (post-sign-in sync, launch download
reconciliation) in a way targeted TODAY tests are unlikely to catch — the failure
mode is an observer that never fires.

---

## FINDING 3 (BLOCK — Check 6): Contract D's AC2 grep (and Contract F's mirrored probe) fails on a CLEAN tree

```
$ grep -rlE 'class (TPPBookRegistry|SideloadedBookRegistry)' Palace --include='*.swift'
Palace/Book/Models/TPPBookRegistry.swift
Palace/Book/Models/TPPBookRegistryRecord.swift   <-- 'class TPPBookRegistryRecord' matches the unanchored regex
Palace/MyBooks/Sideload/SideloadedBookRegistry.swift
```

Count is 3, not 2 — D's AC2 (`test ... = "2"`) fails today and will still fail
after a perfect D implementation. Contract F encodes the same "count: exactly 2
book-state owners" probe into `facts.json`, so F's drift checker would be born red
(or force a sloppy probe). Fix: anchor the pattern, e.g.
`class (TPPBookRegistry|SideloadedBookRegistry)[^A-Za-z0-9]` or match
`final class SideloadedBookRegistry`/`class TPPBookRegistry:` with a trailing
delimiter. Same fix must propagate into F's facts.json probe.

---

## FINDING 4 (required amendment, not standalone block — Check 3): E1's named branch list is incomplete, and two of its "undocumented branches to pin" are ALREADY pinned

- Already pinned today (stale contract claim):
  `PalaceTests/Contract/__Snapshots__/BookReturnServiceContractTests/withoutRevokeURL_skipsNetwork.json`
  and `withRevokeURL_parsingErrorTreatedAsSuccess.json` exist, with matching tests
  (`test_returnBook_withoutRevokeURL_skipsNetwork_clearsLocalContent`,
  parse-fail scenario). Harmless direction-wise, but the contract's "undocumented,
  verified" framing is out of date — the implementer should gap-fill, not re-pin.
- Branches the E1 enumeration does NOT name (the governing "EVERY branch" clause
  covers them, but an implementer anchoring on the named list would miss them):
  - BookReturnService: DRM-connector `returnFulfillment` failure branch
    (`:303–309`, `if !success`); the re-auth fan-out (coordinator vs SAML vs
    browser vs basic-credential sub-paths, `:481–534`); retry-tracker-exhausted
    alert (`:597`); registry-miss early return (`:290`).
  - BorrowOperation: `requiresAdobeDRM` pre-step (`:400–401`); missing
    `acquisitionURL` guard (`:407`); Loan→Hold race error (`:457`,
    `mapping.error`); re-auth circuit breaker
    (`hasBorrowReauthBeenAttempted`, `:648`). Note the 30s timeout
    (`withTimeout`, `:170/:424`) and streaming-HTML skip (`:482`) ARE correctly
    named as gaps — no existing test/snapshot covers them.
  - DownloadStartDispatcher: existing `DownloadStartCoordinatorContractTests`
    pins only the coordinator's 5 state routes; the dispatcher's ~10 branches
    (`processUnregisteredState` open-access decision `:144–150`, streaming-HTML
    `:202`, OverDrive-audiobook deferral `:209–211`, expired+re-borrow `:253`,
    auto-borrow post-check `:260–267`, wifi-only `:274`, initedRequest vs
    defaultAcquisition vs invalid-URL `:280–296`, SAML cookies `:308`, bearer vs
    cookie auth `:312–314`) are all unpinned. The contract acknowledges this
    surface exists; the enumeration should be written into E1 so "every dispatch
    branch" is checkable.
- E's AC1/AC2 verification greps PASS on the current tree (pre-work): the
  `withoutRevokeURL` name and the ≥4-snapshot count are already satisfied, so
  they verify nothing new. Tighten (e.g. require the timeout + streaming-HTML +
  dispatcher snapshot names, raise the count floor).

## FINDING 5 (PASS — Check 4): E2 decision cores are genuinely pure-extractable

- `BorrowOperation` is already half-extracted: `borrowResponseState` (`:188`,
  availability→state map) and `preBorrowWasUnavailable` (`:224`) are pure statics;
  auth-error classification returns a `BorrowErrorDecision` enum
  (`.routeToReauth/.suppressAndClearSpinner/.showGenericError`, `:73–75`) whose
  inputs (error kind, problem doc, registered state, credentials) can all be
  passed by value.
- `DownloadStartDispatcher.processUnregisteredState` (`:144–149`) already RETURNS
  a decision value; remaining branches key on inspectable inputs (state, content
  type, distributor, wifi policy, auth token presence).
- `BookReturnService` branch keys are pure-classifiable (`revokeURL == nil`,
  `downloaded`, `isOfflineNSURLError` is already a pure static `:645`,
  parse-fail/loan-gone/auth-error classification `:414–481`). Caveat the contract
  should state: the re-auth flows are **multi-round** (decision → await
  coordinator outcome → retry-or-stop), so `ReturnReducer` needs an
  outcome-feedback action, not a single-shot reduce. Extractable, but the shape
  should be declared so the E1 shape-equality proof accounts for the second round.

## FINDING 6 (PASS with notes — Checks 1+5): observer census is EXACTLY 9; no cross-contract file collisions

- Census grep (`TPPBookRegistryStateDidChange|postStateNotification|bookStateSubject|bookStatePublisher`)
  over `Palace/` incl. Obj-C (`*.m/*.h` — zero hits) and raw strings (only the
  name decl) confirms exactly the architect's 9 observers and 2 external posters.
  Already-on-Combine consumers (CarPlaySceneDelegate:198, ReaderService:600,
  BookDetailViewModel:272, BookCellModel:259, BookCellModelCache:265,
  AudiobookSessionManager:396) correctly excluded. The count is RIGHT.
- Test-target references not in C's scope but requiring edits when the post dies:
  `PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift:180` and
  `PalaceTests/MyBooks/MyBooksViewModelTests.swift:1049` drive behavior by
  POSTING the notification; `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift:153`
  asserts the name's rawValue. Add them to C's scope so the migration doesn't
  leave red targeted tests.
- No file collisions: C is the only contract touching `MyBooksDownloadCenter.swift`
  (E's manifest scope does not list MBDC at all — the decision cores live in the
  three collaborator files), the only one touching `MyBooksViewModel.swift`;
  E alone owns `CLAUDE.md`; D alone owns `Sideload/**`; C alone owns
  `NSNotification+TPP.swift`. C and E both add files under `PalaceTests/Contract/`
  but different files. The plan.md line "E touches the decision cores —
  coordinated split of that one file [MBDC]" is stale vs the manifest (E needs no
  MBDC edit); harmless.

## FINDING 7 (advisory — Check 6 remainder): other verification greps are sound

B AC1–AC4 verified against tree (exactly 2 `struct Effect<Action, Environment`
files; Store:21 has the Sendable bound, PalaceAuth Effect:11 lacks it — post-change
both pass). C AC1–AC7 syntactically valid and post-state-checkable; C AC4's
pattern covers all three observer forms found (`publisher(for:`, `forName:`,
`onReceive`). A/F ACs fine. Only D-AC2/F's mirrored count probe is broken
(Finding 3), and E-AC1/AC2 are pre-satisfied (Finding 4).

---

## Dispatch recommendation

A, B, D (with the AC2 regex fixed), and E1 are safe to dispatch today. **C must
not dispatch until its contract is amended** per Findings 1+2 (transition-set
seeding from the call-site audit; RegistryState publisher creation + per-observer
target map + badge replacement + empty-registry one-shot tests). E2 may dispatch
behind the E1 gate as written, with the Finding-4 enumeration added and the
multi-round re-auth reducer shape noted. F needs the count-probe regex fix from
Finding 3 before it encodes the 2-owner fact.
