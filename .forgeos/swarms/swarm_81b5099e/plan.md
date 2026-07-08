---
name: swarm_81b5099e-plan
type: immutable
status: active
created: 2026-05-18T19:30:00Z
last_refresh: 2026-05-19
freshness_window: never
owners: [general]
description: Phase 1 Plan — Account State Machine Migration (swarm_81b5099e)
---

# Phase 1 Plan — Account State Machine Migration (swarm_81b5099e)

**Initiative:** init_dde7f99a · **ADR:** docs/architecture/account-state-machine.md
**Base:** develop · **Feature branch:** feature/account-state-machine-3.2.0 (PR #961)

## Goal

Wire the Account.LoadState state machine into AccountsManager and migrate every Bucket A (critical-path) reader of `account.details` / `currentAccount?.loansUrl` to `await account.awaitReady()`. After Phase 1 merges, the F-016 → audiobook race class is unrepresentable on the audiobook open path, the MyBooks borrow path, the bookmark/annotations sync path, the OPDS loans-feed fetch, and the sign-in / age-check / push-notification flows.

Phase 2 (Bucket B display sites) and Phase 3 (Bucket D tests + mutation gate) are out of scope for this swarm.

## Verified call-site inventory (24 sites across 19 files)

Grep-verified during architect triage. Bucket A in Phase 1 scope (~18 sub-sites across 13 files):
- `Palace/Audiobooks/AudiobookSessionManager.swift:889` — audiobook open
- `Palace/CarPlay/CarPlayAudiobookBridge.swift:51` — CarPlay audiobook open
- `Palace/Book/Models/BookRegistrySync.swift:283` — PP-4407 site (`currentAccount.loansUrl`)
- `Palace/Book/Models/TPPBookRegistryAsync.swift:42` — async registry load
- `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift:117,160` — bookmark sync
- `Palace/Reader2/ReaderStackConfiguration/LCP/LCPPassphraseAuthenticationService.swift:32` — LCP fulfillment
- `Palace/OPDS2/OPDSFeedService.swift:317` — OPDS loans feed
- `Palace/OPDS2/Service/UnifiedOPDSService.swift:337` — OPDS unified loans
- `Palace/Notifications/NotificationService.swift:371` — push-driven Holds navigation
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift:281,309,732,736,753,781` — sign-in flow (6 sub-sites)
- `Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift:17` — card creation
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift:52` — age-check gate
- `Palace/Accounts/Library/AccountsManager.swift:731-751` — wiring seam (NOT a Bucket A migration; the source of transitions)

ADR-named files that do NOT have Bucket A sites (debunked by architect): TPPNetworkResponder, TPPSAMLHelper, TPPNetworkExecutor, TPPReauthenticator. They use `currentAccountId` (UUID string) and `userAccount(for:)` (TPPUserAccount, not Account). Skipped.

Bucket B deferred to Phase 2 (display sites in Settings/, Reader2 annotations metadata, etc.). Bucket C (analytics, error-logs) and Bucket D (tests) untouched.

## Modules

| Module | LOC | Files | Parallelism |
|---|---|---|---|
| Accounts-Wiring | ~150 prod + ~120 test | AccountsManager.swift (1 file) | **Prerequisite (sequential)** |
| Audiobooks-MyBooks-Reader2Sync | ~200 prod + ~150 test | 6 files | Parallel batch |
| SignIn-AgeCheck-Notifications | ~180 prod + ~140 test | 4 files | Parallel batch |
| Network-OPDS | ~80 prod + ~80 test | 2 files | Parallel batch |

Total: 4 implementers, 13 files, ~610 LOC edits + ~490 LOC new tests.

## Sequencing

1. **Accounts-Wiring lands first** and merges to `feature/account-state-machine-3.2.0`. Its contract-snapshot tests (init → basicInfoLoaded, loadCatalogs → detailsLoading → detailsLoaded/Failed, reselect → detailsFailed.accountNotFound) pass before any parallel implementer starts. Without this, `awaitReady()` hangs forever in production.

2. **Three parallel implementers** branch from post-wiring HEAD and run in parallel:
   - Audiobooks-MyBooks-Reader2Sync
   - SignIn-AgeCheck-Notifications
   - Network-OPDS
   None touch AccountsManager, Account+State.swift, or AccountStateStore.swift. File scopes are disjoint per the manifest.

3. **Integration:** each implementer's branch rebases onto post-wiring tip, `scripts/verify-pr.sh --quick` runs green, then merged. forge-review gates the squash-merge.

## Key decisions recorded

- **Library-reselect terminal state**: `.detailsFailed(.accountNotFound(uuid: previousUUID))` rather than `.notLoaded`. Rationale: `.notLoaded` leaves lingering `awaitReady()` callers from the prior account hanging until reselect; `.accountNotFound` is the definitive terminal answer.
- **Single-flight ownership**: AccountsManager.loadAccountSetsAndAuthDoc single-flights per-UUID. Account.awaitReady does NOT enforce single-flight at the gate — the state stream's broadcast semantics handle multi-consumer observation.
- **Account.details legacy backing** stays available unchanged. Phase 1 writes to BOTH AccountStateStore (new path) AND Account.details (legacy backing). Bucket C consumers see no behavior change.
- **No feature flag** per ADR direction. Trust the tests + mutation discipline.

## Risks

- **Wiring must merge first.** No feature flag means Bucket A migrations break in production if shipped without the wiring transitions.
- **`Account.loansUrl` is `details?.loansUrl` passthrough.** Migrating `currentAccount?.loansUrl` callers means propagating `async` up the call stack at 5 sites. Some are already in async contexts (easy); some are not (implementers must escalate if they hit a sync-only callsite they can't make async).
- **TPPSignInBusinessLogic has 6 sub-sites in one file.** Highest density Bucket A target; SignIn implementer must add specific F-016 → sign-in-flow regression tests so single-flight + auth-doc-failure paths are pinned.
- **AccountStateStore.shared vs AppContainer DI**: ADR-frozen API reads `.shared` directly. Implementers MUST NOT change. For tests, construct fresh `AccountStateStore()` or use `_resetAllForTesting()` in DEBUG.
- **LCP test matrix discipline** (per CLAUDE.md) applies to Audiobooks-MyBooks-Reader2Sync. Both Palace (DRM) and Palace-noDRM targets must stay green.

## Acceptance criteria (per implementer)

- `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` green.
- Palace-noDRM also green (LCP-matrix scoped implementer only).
- All existing PalaceTests pass.
- New tests per the contract pass.
- Mutation kill rate ≥50% on changed files (`palace_mutate.py`).
- No edits to `Account+State.swift`, `AccountStateStore.swift`, or files outside the implementer's declared scope.

## Acceptance criteria (swarm-level)

- AccountsManager + state-store contract-snapshot tests pin all five ADR-mandated transitions.
- F-016 → audiobook regression repro test (audiobook open under `.detailsLoading` state) passes positively.
- `account.details?` is no longer read on critical paths outside the legacy AccountsManager wiring path and documented Bucket C sites.
