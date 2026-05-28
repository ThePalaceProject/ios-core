---
name: mybooks-verification-checklist
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 180d
owners: [mybooks]
description: Per-area verification reference; refresh before next swarm/rigorous-fix
---

<!-- audit-verified: file paths under Palace/MyBooks/, Palace/Book/UI/BookDetail/BorrowReducer.swift, and PalaceTests/{MyBooks,Contract,ViewModels}/ all verified via `ls` and `find` against current `chore/swarm-rigor-meta-improvement` HEAD (a71b070bf). Line citations for hasBorrowReauthBeenAttempted (BorrowOperation.swift:92, 601), tokenRefreshAttempts (TPPNetworkResponder.swift:34, 369), BookReturnService setProcessing/removeBook (BookReturnService.swift:139, 221) verified via grep. Contract snapshots inventoried from PalaceTests/Contract/__Snapshots__/. The Phase 7 audit synthesis at .forgeos/audits/phase7-synthesis-2026-05-26.md was confirmed referenced by phase7_borrow_path_regressions_2026_05_14.md. The PR #1018 *AuthCoordinator*Tests cited in the user prompt are NOT present locally on this branch and are listed as "scheduled" rather than "extant." -->

# MyBooks area — verification checklist

**Owner area:** `Palace/MyBooks/` (40 files), `Palace/Book/UI/BookDetail/BorrowReducer.swift` (reducer extraction owned by MyBooks lifecycle), and the borrow/return entry points exposed via `Palace/Book/UI/BookDetail/BookDetailViewModel.swift`.

**Purpose:** the architect's first deliverable on ANY swarm or `/rigorous-fix` in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. Critical-path area per CLAUDE.md — every change to `Palace/MyBooks/Download*` is gated on ≥100% mutation kill on the changed file (CLAUDE.md "Mutation testing"). Without this baseline, every new initiative re-discovers Phase 7's 21-service decomposition surface (the F-011/F-014 silent regressions that shipped to release/3.1.0 are a permanent reminder).

**Last refresh:** 2026-05-28 (initial baseline).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (lifecycle entry points + state-mutating sites)

| File | Lines | What it does | Notes |
|------|-------|-------------|------|
| `Palace/MyBooks/MyBooksDownloadCenter.swift` | ~1,558 LOC | Composition root for 21 extracted services; public surface (`startBorrow`, `startDownload`, `cancelDownload`, `addDownloadTask`) is mostly 1-line delegators after Phase 7. | Critical-path: changes need mutation ≥100% on changed Download* siblings. |
| `Palace/MyBooks/MyBooksDownloadCenter+Async.swift` | ~64 LOC | `borrowAsync` 1-line forwarder into `BorrowOperation`. | Post-PR #890; the elephant moved out. |
| `Palace/MyBooks/BorrowOperation.swift` | 684 LOC | Entire borrow lifecycle. `borrowAsync` (line 335), `borrowResponseState` (line 163), per-book reauth circuit breaker (lines 92, 601), `withTimeout` 30s bound (line 145). Closure-injected `fetchBook` / `presentSignInModal` / OIDC silent reauth. | **#if FEATURE_DRM_CONNECTOR** gated init. |
| `Palace/MyBooks/BookReturnService.swift` | 403 LOC | Return state machine. `setProcessing(true)` (line 139) → revoke → `removeBook` (lines 221/248/276/389) → announce. 5 contract snapshots pin the call order. | Critical-path. PR #1018 auth-coordinator migration adds `else` legacy fallback as tech debt. |
| `Palace/MyBooks/DownloadAuthRetryHandler.swift` | 307 LOC | 6-branch auth retry. Browser-session-expired (line 145), no-active-loan, problem-doc-driven re-borrow. Critical-path. | Phase 7 audit confirmed byte-for-byte parity with 3.0.2 inline equivalent (PR #1005). |
| `Palace/MyBooks/TokenRefreshInterceptor.swift` | — | Per-book auth-failure routing; `triggerOIDCReauth` silent path; coordinator handoff. | Per-task budget enforced at responder layer, NOT here. |
| `Palace/MyBooks/DownloadStartDispatcher.swift` | 213 LOC | `processUnregisteredState` + `processDownloadWithCredentials` + `processRegularDownload`. 7-method delegate. | Parameterized over `TPPBookState.allCases` (PR #1004). |
| `Palace/MyBooks/DownloadStartCoordinator.swift` | 205 LOC | `startBorrow` + `startDownloadAsync` + `startDownloadIfAvailable`. Slot-release on `.holding`/error. | Closure-injection for processUnregistered / processWithCredentials / requestCredentials. |
| `Palace/MyBooks/RightsManagementDispatcher.swift` | 200 LOC | Per-rights dispatch: `.unknown` / `.adobe` / `.lcp` / `.simplifiedBearerToken` / `.overdrive` / `.none`. | Two #if-gated init signatures. Adobe non-PDF Task untested (no DRM stub seam). |
| `Palace/MyBooks/LCPFulfillmentHandler.swift` | 216 LOC | LCP license fulfillment. **#if LCP**. | Marketplace LCP MIME-nesting depends on `LCPAudiobooks.hasLCPAcquisition` recursive predicate. |
| `Palace/MyBooks/AdobeDRMHandler.swift` | 183 LOC | NYPLADEPTDelegate. **#if FEATURE_DRM_CONNECTOR**. | |
| `Palace/MyBooks/OverdriveDownloadHandler.swift` | 174 LOC | `x-overdrive-scope` + `x-overdrive-patron-authorization` headers. **#if FEATURE_OVERDRIVE**. | F-081 closed; deferOverdriveFulfillment path. |
| `Palace/MyBooks/BackgroundDownloadHandler.swift` | — | URL-session callbacks. File-move to safe-location + handoff into `handleDownloadCompletion`. | |
| `Palace/MyBooks/DownloadCompletionParser.swift` | 157 LOC | Pre-dispatch parse: rights / problem-doc / OPDS routing / canCompleteDownload. | |
| `Palace/MyBooks/DownloadStateManager.swift` | — | Per-book download-task table + state tracking. | |
| `Palace/Book/UI/BookDetail/BorrowReducer.swift` | — | Pure `reduce(state, action) -> ()`. Exhaustive switch on `TPPBookState` (no `default:` — F-015 systemic guard from PR #890 post-mortem). | F-011 history: missing `.downloadNeeded` case shipped to 3.1.0. |
| `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` | ~833 | `handleAction(_:)` dispatches `.get`/`.reserve`/`.return`/`.download`. Posts `TPPCirculationAnalytics.postEvent("open_book", ...)` at line 833. | The .reserve path uses `attemptDownload: false`; .get path uses `true`. |
| `Palace/Network/TPPNetworkResponder.swift` | 34, 369 | Per-task `tokenRefreshAttempts < 2` budget — preserved through PR #1018 migration. | NOT under MyBooks but consumed by it. |

---

## 2. Module ownership

| Module | Owner | Public surface (what changes here is a contract break) |
|--------|-------|--------------------------------------------------------|
| `Palace/MyBooks/` (main target) | MyBooks area | `MyBooksDownloadCenter` public methods (`startBorrow`, `startDownload`, `startDownloadAsync`, `startDownloadIfAvailable`, `cancelDownload`, `addDownloadTask`, `downloadInfo(forBookIdentifier:)`); `MyBooksDownloadCenterProtocol`; `BookReturnService` + `BookReturnServiceDelegate`; `BorrowOperation` static surface (`clearAllBorrowReauthState`, `borrowResponseState`, `withTimeout`); `TokenRefreshInterceptor` delegate protocol; all 21 service-level delegate protocols established in Phase 7. |
| `Palace/Book/UI/BookDetail/` | MyBooks lifecycle reducer | `BorrowReducer.reduce`, `BorrowState`, `BorrowAction` enum (exhaustive over `TPPBookState`). |
| `Palace/Network/` | Network area (consumed here) | `TPPNetworkResponder` per-task `tokenRefreshAttempts` budget; cross-domain 401 carve-out. |
| `Palace/Packages/PalaceAuth/` | Auth area (consumed here post-PR #1018) | `AuthCoordinator`, `AuthErrorClassifier` — MyBooks routes auth errors through these. |

---

## 3. Distributor × flow matrix

Rows = distributors (verified against `docs/Testing/REGRESSION_TEST_MATRIX.md` rows B1–B9). Columns = flow stages. "auto" = simdrive/contract-test coverage; "manual" = exercise on-device; "UNKNOWN" = no green-path evidence; "n/a" = distributor doesn't support stage.

| Distributor | Borrow (B1) | Hold (B3) | Hold→loan (B7) | Download (B5) | Return (B2) | Re-download after orphan |
|---|---|---|---|---|---|---|
| Palace Bookshelf (DRM-free) | auto + manual | n/a (always available) | n/a | manual | manual | n/a |
| Palace Marketplace LCP | manual | manual | **UNKNOWN — PP-4020 C5 gap** | manual (B6) | manual | manual (PP-3704 fixed orphan; recursive `hasLCPAcquisition` PP-4407) |
| Overdrive (audiobook primary) | manual | manual | manual (F-081 closed) | manual (B6-OD) | manual (F-012 XML-as-JSON parse) | UNKNOWN |
| Findaway | manual | manual | UNKNOWN | manual | manual | UNKNOWN |
| Adobe DRM | manual | manual | **UNKNOWN — PP-4020 C5 gap** | manual (B6-Adobe) | manual | manual (AdobeCertificate crash latent) |
| ODL | manual | manual | UNKNOWN | manual | manual | UNKNOWN |
| Open-access | auto + manual | n/a | n/a | manual | manual | n/a |

simdrive corpus has `concurrent-borrow.yaml` covering B8. `hold-to-loan-lcp.yaml` and `hold-to-loan-adobe.yaml` exist as plans but were never green (B7 LCP + Adobe). B9 (borrow after sign-out / anonymous) is SQ-005 regression — must not show empty sign-in modal.

---

## 4. State-machine surface (BorrowOperation + BookReturnService + BorrowReducer)

### BorrowOperation lifecycle (extracted in PR #890, commit 41)

States are implicit via the registry's `TPPBookState`; the operation drives transitions through these stages:

1. `borrowAsync` (line 335) — `setProcessing(true)` → request loan → parse response
2. `borrowResponseState` (line 163) — pure mapper: response → `(TPPBookState, PalaceError?)`. Default `.downloadNeeded`; sets `.holding` on Hold acquisition. **F-014** lived here: inverted `attemptDownload && state != .downloadNeeded` predicate stranded users at the Download tap; reverted in 5e3476998.
3. Auth-error handling — `BorrowAuthErrorDecision` enum threads decisions out without exposing internals. Calls `hasBorrowReauthBeenAttempted` (line 601) circuit breaker, then routes either to OIDC silent reauth or to sign-in modal.
4. `clearAllBorrowReauthState` (line 113) — MBDC forwarder; central clear on account switch.
5. Timeout — `withTimeout` 30s bound (line 145); F-014 follow-up.

**Canonical contract lock:** `PalaceTests/Contract/BorrowOperationContractTests.swift` with 6 snapshots:
- `401NoProblemDoc_routesToSignInModal.json`
- `alreadyBorrowed_isIdempotent_perSQ007.json`
- `attemptDownloadFalse_onSuccessfulBorrow_doesNotCallStartDownload.json`
- `attemptDownloadTrue_onSuccessfulBorrow_callsStartDownload.json`
- `authError_noAuthDef_fallsThroughToAlert.json`
- `holdResponse_doesNotCallStartDownload.json`

### BookReturnService lifecycle

1. Gate: `bookRegistry.state(for: identifier)` check (line 115); `downloaded = .downloadSuccessful || .used`.
2. `setProcessing(true)` (line 139) → revoke endpoint POST → parse response.
3. Cleanup tail (5 distinct paths): `setProcessing(false)` (lines 144, 154, 192) on failure; `removeBook` (lines 221, 248, 276, 389) on success/no-active-loan/parse-error-treated-as-success/auth-error.
4. PR #803 confirmation alert auto-dismisses; F-012 (revoke endpoint returns XML, client parses as JSON) is a known cross-distributor risk.

**Canonical contract lock:** `PalaceTests/Contract/BookReturnServiceContractTests.swift` with 5 snapshots:
- `authError_triggersReauth.json`
- `genericError_announcesFailure.json`
- `noActiveLoan_treatsAsSuccess.json`
- `withoutRevokeURL_skipsNetwork.json`
- `withRevokeURL_parsingErrorTreatedAsSuccess.json`

### BorrowReducer (pure)

`BorrowState` = `(bookState: TPPBookState, processingButtons: Set<...>, localBookStateOverride: TPPBookState?, ...)`. Actions: `.registryStateChanged(TPPBookState)`, `.downloadErrorOccurred(registryState: TPPBookState)`, `.bookStateAssigned(TPPBookState)`. Switch on `registryState` is exhaustive (PR #890 post-mortem WP3 sweep removed `default:`). `BorrowReducerContractTests.swift` pins the dispatch table.

---

## 5. Telemetry surface

MyBooks does **not** link Firebase directly — emission goes through:

| Surface point | File | Mechanism |
|---|---|---|
| Borrow lifecycle logs | `Palace/MyBooks/BorrowOperation.swift` (lines 343, 347, 360, 366, 370, 416, 424, 697) | `errorActivityTracker.log(..., category: .borrow / .network)` — actor-isolated, in-memory ring buffer; surfaced in diagnostic dumps. |
| Open-book analytics | `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:833` | `TPPCirculationAnalytics.postEvent("open_book", withBook: book)` — only direct circulation-analytics call on the borrow path. |
| Download completion notifications | `Palace/MyBooks/DownloadTaskLifecycleService.swift` | `notifyDownloadCenterDidChange` via delegate; MBDC remains `object: self` for `NSNotification` listeners (registry, BookCellModel, BookDetailViewModel). |
| Alert publication | `DownloadAlertPresenter` / `BorrowErrorPresenter` / `LCPFulfillmentHandler` | `progressReporter.downloadErrorPublisher` Combine pipeline. Tests subscribe to capture `[DownloadErrorInfo]`. |
| Auth-error classification | (post-PR #1018) `PalaceAuth.AuthErrorClassifier` via `AuthDecisionRecorder` wrapper | Coordinator emissions: `classifierOutcome`, `refreshStart`, `refreshEnd`. See `auth/verification-checklist.md` §5. |

**Crashlytics:** no MyBooks code links Firebase. Crash signals reach Crashlytics only via top-level handlers; MBDC's role is to surface `PalaceError` to the publisher so the UI layer can route it.

---

## 6. Test surface

**Inventory (critical-path mutation requirement: ≥100% on `Palace/MyBooks/Download*` per CLAUDE.md):**

Unit tests in `PalaceTests/MyBooks/` (41 files):
- `BorrowOperationTests.swift`, `BorrowOperationTimeoutTests.swift`
- `BookReturnServiceTests.swift`
- `DownloadAuthRetryHandlerTests.swift`
- `TokenRefreshInterceptorTests.swift`
- `MyBooksDownloadCenterTests.swift` + 9 sibling MBDC suites (Eviction, Extended, Integration, Offline, Concurrency, AccountIdThreading, SessionInvalidation, ExtendedTests)
- `DownloadStartDispatcherTests.swift`, `DownloadStartCoordinatorTests.swift`
- `DownloadTaskLifecycleServiceTests.swift`, `DownloadCancellationHandlerTests.swift`
- `BackgroundDownloadHandlerTests.swift`, `DownloadProgressPublisherTests.swift`
- `DownloadFreeSpaceExhaustionTests.swift`, `DownloadResumeAfterKillTests.swift`, `DownloadRMSDKHandoffTests.swift`
- `AdobeDRMHandlerTests.swift`, `OverdriveDownloadHandlerTests.swift`, `OverdriveDeferredFulfillmentTests.swift`, `LCPFulfillmentHandlerTests.swift`
- `RightsManagementDispatcherTests.swift`, `BookFileManagerTests.swift`, `DiskBudgetManagerTests.swift`
- `DownloadCompletionParserTests.swift`, `DownloadStateManagerTests.swift`, `DownloadAlertPresenterTests.swift`, `DownloadAnnouncementServiceTests.swift`
- `BookContentResetServiceTests.swift`, `LocalBookContentServiceTests.swift`, `BookFileManagerTests.swift`
- `BookSignInRedirectHandlerTests.swift`, `CredentialPromptCoordinatorTests.swift`, `BorrowErrorPresenterTests.swift`
- `BookCellModelOfflineTests.swift`, `MyBooksViewModelTests.swift`
- `RedirectPolicyTests.swift`, `RetryClassificationTests.swift`, `UserRetryTrackerTests.swift`
- `MyBooksSimplifiedBearerTokenTests.swift`, `TPPBookBearerTokenTests.swift`, `DownloadErrorInfoTests.swift`

Reducer tests:
- `PalaceTests/ViewModels/BorrowReducerTests.swift` — parameterized `testRegistryStateChanged_clearsAcquireFlags_forAllBorrowCompletedStates` over `[.downloadNeeded, .downloading, .downloadFailed, .downloadSuccessful, .used]` (catches F-011 class drift).

Contract-snapshot tests in `PalaceTests/Contract/`:
- `BorrowOperationContractTests.swift` (6 snapshots — see §4)
- `BookReturnServiceContractTests.swift` (5 snapshots — see §4)
- `BorrowReducerContractTests.swift`
- `DownloadStartCoordinatorContractTests.swift`

**Tests that test BEHAVIOR (must-survive any refactor):**
- Borrow + download chaining for all `TPPBookState` cases (`BorrowReducerTests`).
- Return cleanup contract — setProcessing + removeBook ordering (`BookReturnServiceContractTests`).
- BorrowOperation idempotence on already-borrowed (SQ-005/SQ-007).
- DownloadAuthRetryHandler 6-branch routing.
- Concurrent borrow debounce (B8 simdrive).

**Scheduled (PR #1018 follow-up — not yet present locally):** `BookReturnServiceAuthCoordinatorTests`, `BorrowOperationAuthCoordinatorTests`, `BookReturnCleverReauthTests`, `BorrowOperationCleverReauthTests`. When PR #1018 lands, these replace ad-hoc auth-routing assertions in the existing test classes.

**Reusable patterns:** `feedback_test_patterns_phase7.md` documents the canonical 10 — Combine subscriber, spy delegate per protocol, closure injection for static-method deps, `@MainActor` test class + `waitForAsync`, `FakeDownloadTask` subclass, JSON round-trip for cross-module Codable inits.

---

## 7. Known traps / anti-patterns

- **TPPUserAccount migration safety-net fallbacks** (`incomplete_migrations_antipattern.md` + PR #822 retro): NEVER leave a "safety-net fallback" to the legacy singleton during a migration. PR #822 kept `sharedAccount()` in `AccountsManager.currentUserAccount` when `currentAccountId` was briefly nil — hid the race that produced the spurious login modal during download. Strip legacy from the **protocol** first; let the compiler drive the rest. Audit callers of the protocol, not just the class — injection hides call sites.
- **BiblioBoard cross-host OpenAccessTrack token scoping** (`reference_biblioboard_cross_host_token_scoping.md`): bearer token was scoped to `manifest.originHost`; OPDS-for-Distributors splits manifest (palaceproject.io) from chapter MP3s (distributor CDN). Scope mismatch → 403 → `AVPlayerItem.failed` didn't surface to `playbackStatePublisher` → lock-screen timer walked past playable range with no error. Auth scope must be "hosts CM authorizes me to talk to," not "the host this URL lives on." Applies to LCP license servers, OverDrive Marketplace, Findaway chunked downloads.
- **Marketplace LCP MIME-nesting in `canOpenBook` / `pathExtension`** (`reference_marketplace_lcp_mime_nesting.md` + PR #972 / PR #1008): `LCPAudiobooks.canOpenBook` checked only `defaultAcquisition.type`, missed LCP MIME nested two levels deep (`opds-publication+json → LCP license → audiobook+lcp`). 639MB `.lcpa` ZIP saved as `.epub` → "Failed to parse local file as JSON". Acquisition-chain predicates **must be recursive by default** — OPDS2 nests publication types arbitrarily deep. Diagnostic recipe: `xxd <file> | head -1` (PK\x03\x04 = ZIP/LCP, 504B = EPUB).
- **Per-book reauth circuit breaker** (`BorrowOperation.swift:92`, 601): `hasBorrowReauthBeenAttempted(for: bookId)` is the per-book gate. Process-wide coordinator single-flight is NOT a substitute — both layers serve different roles. Cleared via `clearAllBorrowReauthState` on account switch (line 113).
- **Per-task token-refresh budget** (`TPPNetworkResponder.swift:34`, 369): `tokenRefreshAttempts < 2` per `TPPNetworkResponder` instance, with cross-domain 401 carve-out. Preserved through PR #1018 migration. Don't replace with coordinator-level counters; this is responder-scoped.
- **Legacy `else` fallback in BookReturnService** (PR #1018 tech debt): retained for tests that don't inject a coordinator. Delete when all return-flow tests inject the coordinator seam — until then, BorrowOperation / BookReturnService have an extra branch that must be exercised to prevent silent fallback drift.
- **Reachability subscription pairs** (`feedback_bugfix_PP-4114.md`): BORROW path on `BookCellModel`, IN-PROGRESS DOWNLOAD path on `MyBooksDownloadCenter`. Same `connectivityPublisher` source, otherwise independent — different views, state managers, cleanup. When fixing one, audit the other. Pattern: `dropFirst().filter { !$0 }.receive(on: RunLoop.main).sink { ... }` with sink snapshotting state BEFORE mutation (`failDownloadWithAlert` empties dicts asynchronously).
- **OPDS2 has TWO publication types in the same SPM module** (`feedback_bugfix_PP-4230.md`): `OPDS2Publication` (lightweight) vs `OPDS2FullPublication`. Separate Codable types with separate Metadata structs — drift independently. Lightweight decoder silently drops undeclared fields. Symptom: feature works for some books not others. Adjacent gap: duration hardcoded nil at `OPDS2PublicationExtended.swift:322`.
- **F-011 / F-014 / F-017 silent decomposition bugs** (`phase7_borrow_path_regressions_2026_05_14.md`): PR #890 shipped 3 silent regressions to release/3.1.0 (missing `.downloadNeeded` reducer case, inverted `attemptDownload` condition, BookCellModel ignoring `localBookStateOverride`). Phase 7 audit complete (2026-05-26 synthesis at `.forgeos/audits/phase7-synthesis-2026-05-26.md`) — no live siblings. Decomposition PRs need invariant-pinning tests, not just per-case tests (e.g. "for every borrow-completed state, acquire flags are cleared").
- **`TPPBookRegistryMock.with(account:perform:)` is a no-op** — the closure parameter is the concrete `TPPBookRegistry` class which the mock can't furnish. Code paths through that method aren't unit-testable against the mock; document inline and rely on integration coverage.
- **Adobe non-PDF fire-and-forget Task in `RightsManagementDispatcher`** — currently untested; needs an `AdobeDRMService` protocol seam first.

---

## 8. Architect's pre-swarm checklist

Before any new swarm or `/rigorous-fix` in this area:

1. **Refresh §1's call-site map.** Confirm file sizes + line citations against current `develop`. Phase 7 stabilized the surface; new extractions or merges may have shifted lines.
2. **Re-run `find Palace/MyBooks -name '*.swift' | wc -l`** — expect ~40 files post-Phase 7. Any growth needs categorization in §1.
3. **Re-inventory contract snapshots:** `ls PalaceTests/Contract/__Snapshots__/{BorrowOperation,BookReturnService,BorrowReducer,DownloadStartCoordinator}ContractTests/`. New snapshots are contract additions — note them in §4.
4. **Re-grep `default:` in MyBooks switches:** `grep -n "default:" Palace/MyBooks/*.swift Palace/Book/UI/BookDetail/BorrowReducer.swift` — WP3 systemic sweep removed silent `default:` arms; any new occurrence on a `TPPBookState` switch needs review.
5. **Run critical-path mutation BEFORE changes:** `python3 scripts/palace_mutate.py --file Palace/MyBooks/<file>.swift --tests PalaceTests/<TestClass>` for each touched file. Mutation cache means repeat runs are <1s. Target: ≥100% on `Download*` per CLAUDE.md.
6. **Verify B7 (hold→loan) UNKNOWNs in §3.** If the swarm touches hold-conversion paths, schedule on-device Adobe + LCP waited-out runs — currently the only stages without green-path evidence.
7. **Re-check the auth-area checklist** (`docs/architecture/areas/auth/verification-checklist.md`) for any changes to `AuthCoordinator` / `AuthErrorClassifier` semantics — MyBooks consumes these.
8. **Update §9 with date + initials.**

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | swarm-rigor-meta-improvement architect | Initial baseline derived from MEMORY.md MyBooks entries (Phase 7 handoff, borrow-path regressions, TPPUserAccount retro, BiblioBoard, Marketplace LCP, PP-4114/PP-4230 bugfix tips) + `docs/Testing/REGRESSION_TEST_MATRIX.md` B-rows + contract-snapshot inventory + Phase 7 audit synthesis (2026-05-26). File paths/lines verified via `find`/`grep` on `chore/swarm-rigor-meta-improvement` (HEAD a71b070bf). PR #1018 auth-coordinator follow-up tests listed as "scheduled" — not present locally on this branch. |

---

**This file is owned by the MyBooks area.** If you change anything in §2's modules, update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt.
