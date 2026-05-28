<!-- audit-verified: All file:line citations below were re-confirmed against current HEAD on chore/swarm-rigor-meta-improvement (2026-05-28) by reading the cited source files and grepping for the cited symbols (e.g. `awaitReady`, `currentAccount =`, `_setState`, `.accountNotFound`, `noAccountSentinelUUID`). Recent commit history (14100c62a redrive fix, dce81974e currentAccount setter driver, 49c591b24 wiring-suite isolation flag, 222137d3a state machine PoC, e8cc87d26 develop merge) was verified via `git log --oneline origin/develop -- Palace/Accounts/`. Memories referenced (enum_conflation_account_not_found, phase1_account_state_machine_2026_05_19, reference_tpp_user_account_migration_retro, feedback_wiring_suite_test_isolation) were read in full and their claims cross-checked against current code. Sections marked UNKNOWN are explicitly flagged as unverified at refresh time. -->

# Accounts area — verification checklist

**Owner area:** `Palace/Accounts/` — `Account.swift`, `Account+State.swift`, `Account+profileDocument.swift`, `Account+TPPLibraryAccountReadable.swift`, `AccountsManager.swift`, `AccountStateStore.swift`, `BundledRegistrySnapshot.swift`, `CatalogPreloader.swift`, `CrawlableFeedAnalysis.swift`, `CrawlState.swift`, `LibraryCatalogMerger.swift`, `LibraryRegistryCrawler.swift`, the User subtree (`TPPUserAccount.swift`, `TPPCredentials.swift`, `TPPAccountAuthState.swift`, `UserAccountAuthState.swift`, `UserAccountPublisher.swift` + extension, `UserProfileDocument.swift` + `+Links.swift`, `NYPLADEPT+TPPDRMAuthorizing.swift`), and `AgeCheck/` (`TPPAgeCheck.swift`, `TPPAgeCheckViewController.swift`).

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. Accounts is the spine — `AccountsManager` is the single source of truth for which library is current; `TPPUserAccount` is per-library credential storage; the state machine (`Account.LoadState`) is the readiness gate every cross-area consumer (Audiobooks, MyBooks, Reader2 bookmark sync, CarPlay, OPDS feed service) waits on before it can issue an authenticated request. A regression here is silent until a user's audiobook hangs, a sign-in modal pops on a signed-in user, or credentials from Library A leak into a Library B request.

**Last refresh:** 2026-05-28 (initial baseline; derived from the 2026-05-19 Phase 1 state-machine PoC PR #961, the 2026-05-20 Phase 2 PR #967, the 2026-05-26 swap-back redrive PR #996, and the dce81974e `currentAccount` setter driver fix).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (sites that mutate `currentAccount`, drive `Account.LoadState`, write `TPPUserAccount` credentials, or read `CredentialSnapshot`)

| File | Lines | What it does | Status |
|------|-------|--------------|--------|
| `Palace/Accounts/Library/AccountsManager.swift` | 267-325 | `currentAccount` getter+setter. Setter cleans up active content, writes `.accountNotFound` against the **prior** UUID (state-machine eviction marker, lines 299-304), and calls `driveCurrentAccountAuthDocIfNeeded()` for the new UUID (line 315). | **WIRED** — Phase 1 state-machine cleanup + dce81974e new-account driver. |
| `Palace/Accounts/Library/AccountsManager.swift` | 224-250 | `preloadAccountsFromDiskCacheSync()` — synchronously hydrate `accountSets` from disk cache; drives every preloaded account to `.basicInfoLoaded` (line 242). | **WIRED** — Phase 1 PoC. |
| `Palace/Accounts/Library/AccountsManager.swift` | 525-... (full body), warm-path driver at line 550 | `loadCatalogs(completion:)` — stale-while-revalidate entry. Warm path (in-memory hit) calls `driveCurrentAccountAuthDocIfNeeded()` to close the cold-launch awaitReady() hang (PR #975 / `1fdd59c73`). | **WIRED**. |
| `Palace/Accounts/Library/AccountsManager.swift` | 900-939 | `fetchAuthDocumentWithStateMachine(for:completion:)` — single-flight HTTP fetch + `.detailsLoading` → `.detailsLoaded` / `.detailsFailed(.authDocumentFetchFailed)` transition. Inflight set at lines 904-918. | **WIRED**. |
| `Palace/Accounts/Library/AccountsManager.swift` | 953-973 | `driveCurrentAccountAuthDocIfNeeded()` — re-drives auth-doc when state is non-terminal **OR** when state is the stale `.accountNotFound` eviction marker (lines 958-966). PR #996 fix for library swap-back. | **WIRED** — disambiguation lives here. |
| `Palace/Accounts/Library/AccountsManager.swift` | 977-1027 | `loadAccountSetsAndAuthDoc(...)` — parses OPDS2 feed, carries forward `authenticationDocument` from old → new instances, drives every new account to either `.detailsLoaded` (carry-over) or `.basicInfoLoaded` (lines 1016-1027). | **WIRED**. |
| `Palace/Accounts/Library/Account+State.swift` | 38-44, 79-104, 117-119, 127-141 | `LoadState` enum (5 cases), `awaitReady()` async gate, `_setState(_:)` internal seam, `AccountLoadError` enum (3 cases incl. overloaded `accountNotFound`). | **CANONICAL** — see Section 4 for the enum-conflation pin. |
| `Palace/Accounts/Library/AccountStateStore.swift` | 33-125 | External `[UUID → CurrentValueSubject<LoadState, Never>]` store. State decoupled from Account instance identity because AccountsManager replaces instances on every `loadCatalogs`. | **CANONICAL**. |
| `Palace/Accounts/Library/AccountsManager.swift` | 446-481 | `userAccount(for:)` + `currentUserAccount` getter. `userAccount(for:)` is the per-library `TPPUserAccount` factory (lines 446-457). `currentUserAccount` returns `lastKnownCurrentUserAccount` during the brief nil window (lines 469-481) to ride out the F-016 race. | **MIGRATED** — per-account isolation post-PR #822. |
| `Palace/Accounts/Library/AccountsManager.swift` | 391-411 | `_seedAccountForTesting(_:)` — DEBUG-only seam for Bucket A integration tests (PR #985 follow-up). NOT compiled into release. | Test-only. |
| `Palace/Accounts/User/TPPUserAccount.swift` | 51-... | `@objcMembers class TPPUserAccount: NSObject, TPPUserAccountProvider` — per-library credential store. Keychain keys derived from `libraryUUID`. | **CANONICAL**. |
| `Palace/Accounts/User/TPPUserAccount.swift` | 154-186 | `credentials` getter+setter — atomic under `accountInfoQueue`. | Atomic; never read from `sharedAccount()` in new code. |
| `Palace/Accounts/User/TPPUserAccount.swift` | 196-214 | `sharedAccount()` / `sharedAccount(libraryUUID:)` — class-level delegate kept for legacy/Obj-C test call sites; routes through `AppContainer.production().accountsManager.userAccount(for:)`. | **DO NOT extend** — per migration retro (PR #822 lesson, memory `reference_tpp_user_account_migration_retro.md`). |
| `Palace/Accounts/User/TPPUserAccount.swift` | 505-572 | `CredentialSnapshot` struct + `credentialSnapshot()` instance method + `credentialSnapshot(for:)` class method. Atomic snapshot under `accountInfoQueue.sync`; invalidates all keychain caches on bound instances (line 529). | **CANONICAL** — read sites at Section 5. |
| `Palace/Accounts/User/UserAccountAuthState.swift` | 29-176 | `UserAccountAuthHelper` — pure static helpers for token/credential predicates (`isTokenExpired`, `isTokenNearExpiry`, `hasCredentials`, `resolveAuthState`, `needsAuth`, etc.). | Pure; safe to extend. |
| `Palace/Accounts/User/UserAccountPublisher.swift` | 79-127 | `UserAccountPublisher.shared` — Combine bridge for SwiftUI auth-state observation. Has `updateState(from:)`, `markCredentialsStale()`, `markLoggedIn()`, `signOut()`. Read by SwiftUI extensions at `UserAccountPublisher+Extensions.swift:67,76,89`. | Singleton; observer-only — does NOT own state. |
| `Palace/Accounts/AgeCheck/TPPAgeCheck.swift` | (full file) | Age-check verification flow. Wired into AccountsManager via `ageCheck.verifyCurrentAccountAgeRequirement(...)` at `AccountsManager.swift:1040-1043`. | Lifted through Phase 1 wiring. |

**`currentAccount` SETTER call sites** (production code that picks a new library — every one of these triggers the swap pipeline at `AccountsManager.swift:272-324`):
- `Palace/CatalogUI/Views/CatalogView.swift:257`
- `Palace/AppInfrastructure/TPPAppDelegate.swift:509`
- `Palace/Holds/HoldsViewModel.swift:280`
- `Palace/MyBooks/MyBooks/MyBooksViewModel.swift:286`
- `Palace/Settings/TPPSettingsAccountsList.swift:186`

**`awaitReady()` consumer call sites** (Bucket A migration, must not regress to direct `details?` reads):
- `Palace/OPDS2/OPDSFeedService.swift:353`
- `Palace/OPDS2/Service/UnifiedOPDSService.swift:364`
- `Palace/CarPlay/CarPlayAudiobookBridge.swift:66`
- `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift:132, 200`
- `Palace/Reader2/ReaderStackConfiguration/LCP/LCPPassphraseAuthenticationService.swift:47`
- `Palace/Audiobooks/AudiobookSessionManager.swift:1073`
- `Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift:32`

---

## 2. Module ownership

| Module | Owner | Public surface (what changes here is a contract break) |
|--------|-------|---------------------------------------------------------|
| `Palace/Accounts/Library/` | Main target | `Account`, `AccountDetails`, `AccountsManager` (`TPPLibraryAccountsProvider` + `TPPUserAccountResolving` conformance), `Account.LoadState`, `AccountLoadError`, `AccountStateStore.shared`, `awaitReady()`, `LibraryRegistryCrawler`, `CatalogPreloader`, `LibraryCatalogMerger`, `BundledRegistrySnapshot`, `CrawlState` / `CrawlableFeedAnalysis` |
| `Palace/Accounts/User/` | Main target | `TPPUserAccount` (per-library instance + `sharedAccount()` legacy delegates), `TPPUserAccountProvider`, `TPPCredentials`, `TPPAccountAuthState`, `UserAccountAuthHelper`, `UserAccountPublisher`, `CredentialSnapshot`, `UserProfileDocument` |
| `Palace/Accounts/AgeCheck/` | Main target | `TPPAgeCheck` (`TPPAgeCheckVerifying` conformance), `TPPAgeCheckViewController` |
| `AppContainer` cross-cutting | `Palace/AppInfrastructure/AppContainer.swift` | Owns the single live `AccountsManager` instance. New consumers MUST read `appContainer.accountsManager` — do NOT call `AccountsManager()` directly outside tests. |

---

## 3. `Account.LoadState` state machine (verify before changing transition logic)

**States** (`Palace/Accounts/Library/Account+State.swift:38-44`):
- `.notLoaded` — initial; no state machine has been driven for this UUID.
- `.basicInfoLoaded` — OPDS2 catalog row present (display-only); auth-doc NOT yet fetched.
- `.detailsLoading` — auth-doc HTTP fetch in flight.
- `.detailsLoaded(AccountDetails)` — terminal success.
- `.detailsFailed(AccountLoadError)` — terminal failure (3 sub-cases: `.authDocumentFetchFailed`, `.malformedAuthDocument`, `.accountNotFound` — see Section 4).

**Driver transitions** (forward-only under cold-launch; cycles only on library-reselect or user-initiated retry):

| Trigger | Driver function | Transition |
|---------|-----------------|------------|
| Init / cold launch | `preloadAccountsFromDiskCacheSync()` (`AccountsManager.swift:224-250`) | `.notLoaded` → `.basicInfoLoaded` (line 242) |
| Cold launch network refresh | `loadAccountSetsAndAuthDoc(...)` (`AccountsManager.swift:977-1027`) | New instance → `.detailsLoaded` (carry-over, line 1023) **or** `.basicInfoLoaded` (line 1025) |
| Cold launch (current account) | `fetchAuthDocumentWithStateMachine(for:)` (`AccountsManager.swift:900-939`) | `.basicInfoLoaded` → `.detailsLoading` → `.detailsLoaded` / `.detailsFailed(.authDocumentFetchFailed)` |
| Warm cold launch (in-memory hit) | `loadCatalogs` warm path → `driveCurrentAccountAuthDocIfNeeded()` (line 550) | Drives non-terminal → terminal |
| Library switch (prior UUID) | `currentAccount` setter (`AccountsManager.swift:299-304`) | Prior UUID → `.detailsFailed(.accountNotFound)` (**eviction marker**, NOT a real failure — see Section 4) |
| Library switch (new UUID) | `currentAccount` setter → `driveCurrentAccountAuthDocIfNeeded()` (line 315) | New UUID drives past `.basicInfoLoaded` |
| Library swap-back (returning to a UUID that has the stale eviction marker) | `driveCurrentAccountAuthDocIfNeeded()` (lines 958-966) | `.detailsFailed(.accountNotFound)` → `.detailsLoading` → terminal (PR #996 redrive fix) |

**Single-flight invariant:** `fetchAuthDocumentWithStateMachine` guards on `inflightAuthDocFetches` (`AccountsManager.swift:904-918`). Concurrent `awaitReady()` callers do NOT cause duplicate HTTP requests — the `CurrentValueSubject` broadcast at `AccountStateStore.swift:45,89` handles multi-consumer observation.

**Canonical round-trip test:** `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` — `testLibraryReselect_reentry_resetsState_andRedrives` (line 769) drives A → B → A via the production `currentAccount` setter and asserts the round-trip resolves. `testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives` (line 852) is the canonical reference for the CLAUDE.md round-trip wiring pattern (CLAUDE.md Test 7).

---

## 4. `.accountNotFound` enum conflation pin (overloaded — disambiguation required)

`AccountLoadError.accountNotFound(uuid:)` (`Account+State.swift:140`) is currently written for **two semantically distinct** meanings:

1. **Real failure** — "AccountsManager doesn't know about this UUID" (docstring intent: load pipeline raced library-removal).
2. **Eviction marker** — written by `currentAccount` setter (`AccountsManager.swift:299-304`) against the **prior** UUID during a library switch, to terminate awaiters still holding a reference to the prior account.

**Symptom patched at:** `driveCurrentAccountAuthDocIfNeeded()` (`AccountsManager.swift:958-966`) — when the account holding the marker is back to being the current account, the marker is stale; re-drive instead of throwing. Commit `14100c62a` (PR #996).

**Root not yet split.** CLAUDE.md round-trip rules require: *"Enum cases reused with two meanings get an explicit semantics test."* The wiring suite holds 3 tests that pin the disambiguation:
- Test 6 (`testLibraryReselect_priorAccount_terminatesWithAccountNotFound`, line 631) — pins the eviction-marker semantic.
- Test 7 (`testLibraryReselect_reentry_resetsState_andRedrives`, line 769) — pins the round-trip through the production seam.
- `testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives` (line 852) — pins consumer-side disambiguation.

**Backlog refactor** (memory `enum_conflation_account_not_found`): split into `.accountUnknown(uuid:)` (real failure) + `.accountEvicted(uuid:)` (transient marker). Scope ~50-80 LOC; touch points are `Account+State.swift:140`, `AccountsManager.swift:299-304` and `:953-973`, and the 3 wiring tests above. Not urgent — the 121246f85 / PR #996 fix is correct — but worth doing before a third `awaitReady()` consumer lands.

**Reviewer checklist:** any new `AccountStateStore.shared.setState(.detailsFailed(.accountNotFound(...)), ...)` write site needs a disambiguation pin test. Any new `awaitReady()` consumer that catches `AccountLoadError` needs to decide whether `.accountNotFound` is a hard fail or a soft re-drive trigger — and a test for that decision.

---

## 5. Credential isolation surface (per-account `TPPUserAccount` instances)

| Boundary | File | Lines | Invariant |
|----------|------|-------|-----------|
| Per-library instance factory | `AccountsManager.swift` | 446-457 | `userAccount(for:)` — one cached `TPPUserAccount` per UUID; keys derived from `libraryUUID` and immutable for that instance's lifetime. |
| Current-account resolver | `AccountsManager.swift` | 469-481 | `currentUserAccount` returns `lastKnownCurrentUserAccount` during the brief `currentAccountId == nil` window — closes the F-016 spurious-login-modal race. Falls back to `noAccountPlaceholder` only on truly fresh install (`noAccountSentinelUUID` at line 437). |
| Singleton legacy delegate | `TPPUserAccount.swift` | 196-214 | `sharedAccount()` / `sharedAccount(libraryUUID:)` route through the per-account path. **Kept only for Obj-C / legacy test sites** — do not extend (PR #822 retro). |
| Atomic snapshot | `TPPUserAccount.swift` | 526-550 | `credentialSnapshot()` runs under `accountInfoQueue.sync`; invalidates all keychain caches on bound instances before reading (line 529). Race-free under the per-account model because keys are immutable. |
| Snapshot class delegate | `TPPUserAccount.swift` | 556-572 | `credentialSnapshot(for:)` — class-level forward to `accountsManager.userAccount(for: id).credentialSnapshot()`. Empty-UUID fallback returns a no-credentials snapshot (lines 559-570) instead of mutating singleton state. |
| Cross-account contamination guard | `AccountsManager.swift` | 282 | `cleanupActiveContentBeforeAccountSwitch(from:to:)` cancels non-essential network tasks + clears `MyBooksDownloadCenter.clearAllBorrowReauthState()` before the new UUID is assigned. |
| Token-cache invalidation on switch | `AccountsManager.swift` | 285 | `ImageCache.shared.evictDecodedImages()` on switch. |

**Read sites that must remain per-account:** any code that takes `accountId` should capture it at request-start and thread it through, not re-resolve via `currentAccountId` mid-flight. `Palace/Network/TPPNetworkExecutor.swift:491,520,585` is the canonical example — `capturedAccountId` is preserved through the async boundary, fallback to `currentAccountId` only as last resort.

---

## 6. Test surface

**Existing test files** (236 `test*` methods across the suite as of 2026-05-28):
- `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` — **canonical round-trip reference per CLAUDE.md** (Test 7 pattern). Wiring tests for `preload`, `loadCatalogs warm path`, `library-switch driver`, `library-reselect`, single-flight, eviction-marker semantics, swap-back redrive.
- `PalaceTests/Accounts/AccountsManagerTests.swift` — broader `AccountsManager` surface.
- `PalaceTests/Accounts/AccountsManagerCacheTests.swift` — disk-cache hydration + carry-over.
- `PalaceTests/Accounts/AccountStateMachineTests.swift` — `LoadState` enum + `awaitReady` unit tests.
- `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` — `cleanupActiveContentBeforeAccountSwitch` invariants.
- `PalaceTests/Accounts/AccountDetailsTests.swift` + `AccountDetailsURLTests.swift` + `AccountProfileDocumentTests.swift` — auth-doc parsing.
- `PalaceTests/Accounts/AccountModelTests.swift` — Account model basics.
- `PalaceTests/Accounts/CatalogCacheMetadataTests.swift` — cache-freshness predicates.
- `PalaceTests/Accounts/UserAccountPublisherTests.swift` — Combine bridge.
- `PalaceTests/Accounts/TPPPerAccountIsolationTests.swift` — per-account `TPPUserAccount` cache stability, credential isolation, concurrent access (8 tests).
- `PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift` — end-to-end multi-library scenarios (sign-in A → switch B → sign-in B → verify A intact; 500-iteration rapid-switching contamination check; F-034 6-year-old TOCTOU race).
- `PalaceTests/Accounts/AgeCheck/TPPAgeCheckStateMachineTests.swift` — age-check flow.

**Tests that test BEHAVIOR (must-survive any refactor):**
- Library switch end-to-end (cleanup → state-machine eviction marker → new-account driver)
- Library swap-away/swap-back round-trip (Test 7 — `.accountNotFound` marker must redrive, not stick)
- Per-account credential isolation (writes to A don't observe in B's snapshot)
- F-034 TOCTOU race (`TPPCredentialIsolationE2ETests`)
- `awaitReady()` single-flight under concurrent callers
- Cold-launch warm-path driver (PR #975 — auth-doc fetch fires even when accountSets is hot)
- `currentUserAccount` stability across the transient `currentAccountId == nil` window

**Tests that test IMPLEMENTATION (can be rewritten when underlying changes):**
- Direct `_setState(...)` assertions in non-round-trip tests — those prove storage works, not wiring.
- Assertions on specific call orders inside the legacy `sharedAccount()` delegate (relevant only until the singleton delegate is removed).
- AgeCheck `.notLoaded/.basicInfoLoaded` Task branch may be unreachable post-wiring per memory `phase1_account_state_machine_2026_05_19.md` — re-verify before deleting.

---

## 7. Known traps / anti-patterns (lessons from prior work)

- **`.accountNotFound` enum case is overloaded** (Section 4 + memory `enum_conflation_account_not_found.md`) — currently both "real failure" and "eviction marker." Disambiguation lives in `driveCurrentAccountAuthDocIfNeeded()` lines 958-966. Any new `.accountNotFound` write site needs a disambiguation pin test. Split into `.accountUnknown` + `.accountEvicted` is in backlog (~50-80 LOC).
- **AccountsManager wiring-suite has a known test-isolation flake** (memory `feedback_wiring_suite_test_isolation.md`). `AccountsManager.init()` spawns `DispatchQueue.global(qos: .background).async { loadCatalogs(...) }` (line 213) that outlives the test. In the full suite, lingering background work writes through to `AccountStateStore.shared` mid-test of the next case. Mitigation: DEBUG-only `deferInitialLoadCatalogsForTesting` flag (line 170) — suite-level `setUp` flips it on. Always re-run failing wiring tests in isolation (`-only-testing:PalaceTests/AccountsManagerStateMachineWiringTests/testFooBar`) before assuming a regression.
- **`TPPUserAccount.sharedAccount()` is a legacy delegate, not a singleton to extend** (memory `reference_tpp_user_account_migration_retro.md`). PR #822 was an incomplete migration; the safety-net fallback caused spurious sign-in modals (PR #822 retro). Rule: never read credential state from `sharedAccount()` in new code — always go through `accountsManager.userAccount(for: capturedId).credentialSnapshot()`.
- **Per-account `TPPUserAccount` instances are isolated via immutable keys**. The TOCTOU race comes back the moment a caller flips `libraryUUID` on a shared instance. Covered by `TPPCredentialIsolationE2ETests` (F-034 6-year-old race, fixed in PP-4020) — these tests are the contract; do not weaken them.
- **`currentUserAccount` ride-out window** (`AccountsManager.swift:469-481`): during a library switch, `currentAccountId` is transiently nil between the old-id clear and the new-id assignment. `lastKnownCurrentUserAccount` returns the last-resolved instance to prevent consumers (`MyBooksDownloadCenter`, etc.) from observing `hasCredentials == false` on a signed-in account. Removing this fallback re-introduces the spurious sign-in modal.
- **Library swap-back leaves a stale `.accountNotFound` marker** unless the driver disambiguates it (PR #996 / `14100c62a`). Any refactor of `driveCurrentAccountAuthDocIfNeeded()` MUST preserve lines 958-966 or split the enum first.
- **`AccountsManager.init()` background `loadCatalogs` is unconditional in production** (line 213) — do NOT remove the dispatch without re-verifying every cold-launch consumer. The post-init dispatch is what hydrates auth docs after the sync disk-cache pre-load.
- **`accountSets` is replaced wholesale by `loadAccountSetsAndAuthDoc`** (line 1005). Account instance identity is NOT stable across calls — this is exactly why `AccountStateStore` is keyed by UUID, not instance. Any code holding a long-lived `Account` reference must re-fetch via `account(uuid)` or it will silently observe stale state.
- **`UserAccountPublisher.shared` is an observer**, not a state owner — it broadcasts changes via Combine. SwiftUI views read it (e.g. `UserAccountPublisher+Extensions.swift:67,76,89`), but writes always go through the per-account `TPPUserAccount`. Do not mutate auth state via the publisher.
- **`AccountStateStore.shared` is internal-scoped** (`state(for:)` and `stateStream(for:)` are `internal` despite the class being `public`) because `Account.LoadState`'s enclosing `Account` is internal. See `AccountStateStore.swift:50-57` rationale. Re-publishing requires also elevating `Account` to public; out-of-scope for the wiring module.

---

## 8. Architect's pre-swarm checklist (what to verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh this file's sections 1-3** — confirm the call-site map, state-machine driver list, and dispatch matrix are still accurate. Add new `currentAccount` setter sites or `awaitReady()` consumers.
2. **Re-run scattered-predicate grep** — `grep -rn "accountsManager.currentAccount\s*=" Palace/` (5 known sites today). New matches need triage.
3. **Re-run `awaitReady()` consumer grep** — `grep -rn "awaitReady" Palace/` — confirm every consumer either tolerates `AccountLoadError` (Bucket C legacy-tolerant) or has a recovery path (Bucket A critical).
4. **Verify state-machine wiring tests still pass in isolation** — run `AccountsManagerStateMachineWiringTests` ALONE (suite-level isolation flake is real per Section 7). Specifically Test 6, Test 7, and `testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives`.
5. **Verify credential-isolation tests cover the TOCTOU surface** — `TPPCredentialIsolationE2ETests` (5 tests) + `TPPPerAccountIsolationTests` (8 tests). The 500-iteration rapid-switch test is the chaos gate.
6. **Check for any new `.accountNotFound` write sites without disambiguation pin tests** — `grep -rn "\.accountNotFound" Palace/`. Today: 1 write site (`AccountsManager.swift:301`), 1 read site (`:958`), 1 enum-def site (`Account+State.swift:140`). Any addition is a Section 4 violation.
7. **Confirm `sharedAccount()` call sites haven't multiplied** — `grep -rn "TPPUserAccount.sharedAccount" Palace/`. Should remain test-only / Obj-C legacy.
8. **Re-check must-survive-behavior tests pass against current `develop`** BEFORE the swarm starts, so post-swarm regressions are attributable.
9. **Update Section 9 (refresh history)** with date + your initials.

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | chore/swarm-rigor-meta-improvement (initial baseline) | Derived from Phase 1 state-machine PoC (PR #961 / `222137d3a`), Phase 2 migration (PR #967 / `2f5b4339f`), warm-path driver gap (PR #975 / `1fdd59c73`), currentAccount setter driver (PR #985 / `dce81974e`), library swap-back redrive (PR #996 / `14100c62a`), wiring-suite isolation flag (PR #995 / `49c581b24`). Memories consulted: `enum_conflation_account_not_found`, `phase1_account_state_machine_2026_05_19`, `reference_tpp_user_account_migration_retro`, `feedback_wiring_suite_test_isolation`, `singleton_audit_2026_04_24`, `saml_two_surface_auth_model`, `debug_protocol_auth_regressions`, `investigation_icarus_oidc_auth_loss_2026_05_14`. |

---

**This file is owned by the accounts area.** If you change anything in the modules listed in Section 2 — particularly `AccountsManager.currentAccount`, the `Account.LoadState` state machine drivers, the `AccountLoadError` enum, or the per-account `TPPUserAccount` factory — update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt.
