# Architect review — swarm_495a88d9 (Side Loading, PP-2677/2678/2679)

**Reviewer:** architect-reviewer
**Date:** 2026-07-01
**Worktree:** ios-core-sideloading @ feature/PP-2677-sideloading
**Method:** ran the cited greps/reads against the real tree — did not take contracts at their word.

## VERDICT: **BLOCKED** → **RESOLVED** (contracts updated 2026-07-01; see Resolution section at bottom)

The plan and the A/B module contracts are accurate and implementable. **Two concrete
correctness defects are baked into contracts C and D** (findings 1 & 2), plus two
real hazards (3 & 4) and one caveat (5). Findings 1–2 will cause the implementer to
ship a lane that vanishes on facet navigation (AC5) and a rehydration wired against a
misidentified sync site. All are cheap **contract** fixes — the architecture (locked
decisions, exemption-at-reconciliation-core, AppContainer additive pattern) is sound.

---

## Findings

### FINDING 1 — [HIGH / BLOCKING] Module D undercounts the `toCatalogContent()` call sites — lane vanishes on facet cache-hit
The D contract says inject "at the toCatalogContent() call sites in load()(:166) /
applyFacet(:308) / applyEntryPoint(:362,:381)" — **4 sites**. There are **5**:

| line | method | branch |
|------|--------|--------|
| 166 | `load()` | — |
| **283** | `applyFacet()` | **cache-HIT (synchronous fast path)** — MISSED by contract |
| 308 | `applyFacet()` | cache-MISS |
| 362 | `applyEntryPoint()` | cached |
| 381 | `applyEntryPoint()` | fetched |

`:283` and `:308` are **mutually exclusive branches** (verified: `:281 if let cachedFeed = repository.cachedFeed(for: href)` returns at `:294`; `:308` is the else/network path). An implementer following the contract literally patches only `:308`, so **every facet applied from cache (the common path) drops the Side Loaded lane** — a silent AC5 regression that unit tests keyed to `load()` won't catch.
**Fix:** contract must enumerate all 5 sites (or refactor to a single choke point — e.g. push the `prepending:` injection into a wrapper all five call). Add a test case: "applyFacet cache-hit still shows the Side Loaded lane."

### FINDING 2 — [HIGH / BLOCKING] Module C's rehydration anchor `TPPAppDelegate:218` is NOT a launch sync
The C contract + plan R2 say "wire rehydrateAtLaunch between the registry `load()`
(`:200`) and the first launch `sync {}` (`:218`)." Verified: **`:218` is inside
`handleAppRefresh(task:)` (starts `:214`) — the BGAppRefresh background handler**, not
the launch path. `load()` at `:200` is inside `applicationDidFinishLaunching` (`:35`),
which contains **no `sync()` at all**. The real first runtime syncs are
`applicationDidBecomeActive` **`:330`** (fires on cold-launch foreground) and
`AppTabHostView.swift` **`:260`** (catalog appear). The contract's grep gate
("rehydration on a line between :200 and :218") is semantically meaningless — it would
pass for a call placed anywhere textually before line 218, including the wrong method.
An implementer who opens `:218` to place the call "before the first sync" lands in the
background-refresh handler and is misled.
**Fix:** anchor rehydration explicitly inside `applicationDidFinishLaunching`
immediately after `load()` (`:200`), and rewrite the verification to assert it appears
in `applicationDidFinishLaunching` (not "before :218"). Note the exemption itself
protects persistence regardless of ordering (it reads `SideloadedBookRegistry` live),
so worst case of getting this wrong is "book absent until rehydration runs," not data
loss — but the wiring is still wrong as written.

### FINDING 3 — [MEDIUM] `load()` is async; synchronous rehydrate-right-after may be clobbered
`bookRegistry.load()` (`:200`) is explicitly asynchronous — the in-code comment
(`:195-200`) states "load() returns immediately — the disk I/O is dispatched onto the
store's own queue … queues the state transition to .loaded." `rehydrateAtLaunch()`
calls `TPPBookRegistry.addBook`. Calling it synchronously right after `load()` returns
risks the addBook running while the registry is `.unloaded/.loading`, then being
overwritten when the disk snapshot lands and transitions to `.loaded`.
**Fix:** contract C must specify rehydration hooks into `load()`'s completion / the
`.loaded` transition (or prove `addBook` during `.loading` survives the snapshot merge).
This is the actual R2 race, not the sync-ordering framing in the current contract.

### FINDING 4 — [MEDIUM] File path is account-scoped; sideloaded books are account-agnostic
Reader resolves `book.url` → `AppContainer…downloadCenter.fileUrl(for: identifier)`
(`TPPBook+Additions.swift:15-16`) → `fileUrl(for: identifier, account: accountsManager.currentAccountId)`
(`BookFileManager.swift:55-64`) → `fileUrl(for: book, account:)` builds
`<dir(for: account)>/content/<sha256(id)>.<ext>` (`:69-73`). The path is **scoped to
`currentAccountId`**. C's contract says copy to `fileUrl(for: book, account:)` but never
pins the account. If the copy account ≠ the current account at read time, the reader
resolves a different directory and gets nil → open fails. And because
`SideloadedBookRegistry` is deliberately local-only/account-agnostic, **switching
libraries changes `currentAccountId` and makes the sideloaded file unresolvable** — a
real limitation not listed in the plan's risks.
**Fix:** contract C must pin the copy to `accountsManager.currentAccountId` (matching
read time) and document the cross-account limitation, or store under a fixed sideload
pseudo-account and confirm the reader path resolves it.

### FINDING 5 — [LOW / document] `didSelectRead` runs `ensureAuthAndExecute` — an auth gate the "sufficient, no edits" claim omits
`didSelectRead` (`:844`) wraps the open in `ensureAuthAndExecute` (`:711`), which
presents a sign-in modal when `account.needsAuth && !account.hasCredentials()` or
`authState == .credentialsStale`. Opening a sideloaded open-access book **while signed
out on an auth-required library shows sign-in, not the reader**. The contract's
"reader-open sufficiency: no availability/download-record/OPDS gate" is technically
true (this is an auth gate, not those), but the blanket "SUFFICIENT with NO other
production edits" glosses over it. Acceptable for the signed-in DRM-test use case;
should be documented so the E2E tester signs in first.

---

## Verified CORRECT (no action)

**Module A (accurate + robust):**
- `BookRegistrySync.swift`: `recordsToDelete = Set(registry.keys)` at **:406** ✓;
  eviction `registry.removeValue` at **:481** ✓; on-disk delete
  `downloadCenter.deleteLocalContent` at **:497** ✓. Adding
  `recordsToDelete.subtract(sideloadedIDsProvider())` after `:406` exempts BOTH the
  un-registration and the file delete, and sits **before** the `shouldSkipBulkDeletion`
  guards (`:455-469`) as required. ✓
- init at **:64-75** with the lazy `downloadCenterProvider` precedent (`:43`, `:67`) —
  the proposed `sideloadedIDsProvider` default mirrors it exactly. ✓
- Both `BookRegistrySync(` construction sites in `TPPBookRegistry.swift` at **:212**
  and **:242** ✓ (note :242 is the `fileprivate init(account:)` used by
  `with(account:perform:)` — it also gets the exemption via the default, good).
- `@unchecked Sendable` + documented invariant at `:9-31`; storing the provider as
  `let` preserves it. ✓
- **Exemption is centralized at the reconciliation core**, so ALL sync() callers are
  covered by one subtract. Verified sync() fan-in: `AppTabHostView:260`,
  `TPPAppDelegate:218/:330`, `HoldsViewModel:255/:273`, `TPPSignInBusinessLogic:892`,
  `OverdriveDownloadHandler:120`, `MyBooksViewModel:204/:219`, `NotificationService:625`,
  `BookReturnService:616` — all funnel through `BookRegistrySync.sync()`. The plan's R2
  worry about "other launch sync sites" is moot for the exemption (only matters for
  rehydration, see finding 2/3).
- **Off-limits eviction list is complete.** `TokenRefreshInterceptor.swift` and
  `DownloadAuthRetryHandler.swift` exist but do **not** evict/reconcile (no
  `deleteLocalContent`/`recordsToDelete`). Other `deleteLocalContent` sites
  (`BookReturnService`, `MyBooksViewModel:143`, `BookContentResetService`,
  `TPPBookRegistryAsync:118`, `ReaderService:505`) are **user-initiated** deletes, not
  automatic reconciliation — correctly out of exemption scope.
- **Critical regression test is writable.** `sync()` fetches its feed via
  `opdsFeedService.fetchFeed(from: loansUrl, …)` (`:382`); spy seams exist
  (`downloadCenterProvider` for recording `deleteLocalContent`, `opdsFeedServiceProvider`
  for feed injection, `BookRegistryStore` for seeding a `.downloadSuccessful` book).
  Existing `PalaceTests/Book/BookRegistrySyncTests.swift` demonstrates the spy
  construction AND the non-trivial `loansUrl`/`awaitReady` account setup the regression
  test will need to replicate. **Implementer note:** the loans-feed injection requires
  an account whose `details.loansUrl` resolves (see the anonymous-library setup at
  `BookRegistrySyncTests:448-561`) or `sync()` bails before reconciliation.

**Module B (all line refs accurate):** `isTriageBotEnabled` DEBUG-on at **:249-258**,
`inAppPlaybackNavLocalOverrideKey` at **:320**, `managerKey` at **:76** (inAppPlaybackNav
arm :94-95), `RemoteConfigKey` enum at **:55** (inAppPlaybackNav :65),
`setDefaultValues()` at **:102** (entry :112). Contract correctly notes
`inAppPlaybackNavEnabled` lacks DEBUG-on and to borrow it from `isTriageBotEnabled`. ✓

**AppContainer wiring:** `bookOpenTracker` lazy-cache precedent at **:230-236** (contract
said :229-236 — accurate); `_resetForTesting()` at **:546** (contract cited :584-588 —
**stale by ~40 lines**, minor; the method exists). SideloadedBookRegistry is a
file-backed shared static cache, so it **must** be nil'd in `_resetForTesting` to avoid
cross-test-class pollution — treat the contract's "ONLY IF" as "YES." ✓

**Dependency graph accurate:** D reads `appContainer.sideloadedBookRegistry.allBooks` at
the sole `CatalogViewModel(` construction site `AppTabHostView.swift:74-79` and does
**NOT** modify `AppContainer.swift` — confirmed. So C∥D collide on AppContainer via C
only; the A→C staging is the sole AppContainer ordering constraint. `CatalogViewModel.init`
at **:53-66** uses closure injection (`topLevelURLProvider`) — the proposed
`sideloadedLaneBooksProvider` mirrors it. `CatalogLaneModel` at **:417**. ✓

**Reader-open EPUB/PDF (biggest assumption — verified at the seam):**
`BookButtonMapper.swift:48-49` maps `.downloadSuccessful` from registry state alone;
`BookService.open` (`:26`) EPUB→`readerService.openEPUB`, non-LCP PDF→
`downloadCenter.fileUrl(for: book.identifier)`→`TPPPDFDocument(url:)`; no OPDS refetch /
availability / download-record gate; `#if FEATURE_DRM_CONNECTOR` (`:848`) is skipped for
a no-credentials open-access book. Confirmed **modulo findings 4 (account scoping) and 5
(auth gate)** — those are the two seams the "no edits" claim glosses.

---

## Instructions for implementers (once contracts are fixed)
- **D:** patch all 5 `toCatalogContent()` sites (or a single choke point) + add the
  facet-cache-hit lane test.
- **C:** anchor rehydration in `applicationDidFinishLaunching` after `load()`, hooking
  the async-load completion (finding 3); pin the file copy to `currentAccountId`
  (finding 4); document the auth-gate + cross-account caveats (findings 4/5).
- **A:** reset `_sideloadedBookRegistry` in `_resetForTesting`; regression test needs
  a `loansUrl`-resolving account (see BookRegistrySyncTests pattern).

---

## Resolution (architect-directed contract edits, 2026-07-01)

Each finding → the exact contract edit that resolves it. No code was written; all
fixes are in the contracts / plan / manifest so implementers cannot land the defect.

| # | Sev | Resolution | Where |
|---|-----|-----------|-------|
| 1 | HIGH/BLOCK | Contract D now enumerates all **5** `toCatalogContent()` sites (166/283/308/362/381) and **mandates a single choke-point helper** `withSideloadedLane(_:)` that every site routes through. Added grep gates: exactly one `toCatalogContent(` in CatalogViewModel, zero bare `.toCatalogContent()`, `withSideloadedLane(` ≥ 5. Added test case 5 (applyFacet cache-HIT drives the VM, not just the pure fn). | `contracts/D-SideloadedLane.md` (Design + Test contract + Verification); `manifest.yaml` D prompt + AC5 |
| 2 | HIGH/BLOCK | Contract C rehydration anchor corrected: `:218` is `handleAppRefresh` (background), NOT launch. Re-anchored to `applicationDidFinishLaunching` / `setupBookRegistryAndNotifications()`. Grep gate rewritten to assert the call is in that method and NOT in `handleAppRefresh`. | `contracts/C-Manager-and-Settings.md` (Launch rehydration + Verification); `manifest.yaml` C prompt |
| 3 | MED | Rehydration mechanism pinned to the **`bookRegistry.load(completion:)` callback** (load is async; a synchronous rehydrate is clobbered by the disk snapshot). Grep gate asserts `load(` on that path passes a trailing closure. R2 in plan.md rewritten to this race. | `contracts/C` (Launch rehydration); `plan.md` R2 |
| 4 | MED | New **Component 4** in contract A: `BookFileManager` gains account-stable read resolution — sideloaded ids resolve against a fixed `sideloadContentAccountID` (= `AccountsManager.TPPAccountUUIDs[0]`, no-subpath dir) regardless of `currentAccountId`. `BookFileManager.swift` + a resolution test added to A's scope. Contract C's import pins the **write** to the same constant. New R6 in plan.md; new AC5b. | `contracts/A` (Component 4 + scope + test + greps); `contracts/C` (import step 3); `plan.md` R6; `manifest.yaml` A scope/prompt + C prompt + AC5b |
| 5 | LOW | Documented as **accepted limitation (option a)** in contract C + plan.md: `didSelectRead` → `ensureAuthAndExecute` shows sign-in when signed out on an auth-required library; not engineered around (shared critical-path auth gate); E2E signs in first. New R7. | `contracts/C` (Reader-open sufficiency); `plan.md` reader-open caveats + R7 |

Plus the two "verified correct" nits folded in: A now nils `_sideloadedBookRegistry`
in `_resetForTesting` (REQUIRED, not "only if"), and A's regression-test note cites
the `BookRegistrySyncTests:448-561` loansUrl-resolving account setup.

**Intended verdict after these edits: APPROVED for dispatch.** The two correctness
defects (1, 2) are structurally gated (choke-point grep + method-anchored grep), the
two hazards (3, 4) have concrete mechanisms pinned in the contracts, and the caveat
(5) is an explicit accept. Re-review only the C/D diffs against these gates at
integrate.
