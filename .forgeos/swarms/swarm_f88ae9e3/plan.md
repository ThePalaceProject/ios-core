# swarm_f88ae9e3 — iOS Test Flakiness Investigation Plan

## Status
**Investigation only.** No production-code or test-file changes will be made by
investigators. Output is a unified permanent-fix plan, NOT an implementation.

## Problem statement

Develop CI has been failing since 2026-05-28 14:44 UTC. Eight consecutive
develop runs failed; PRs #1020-#1025 all showed `mergeStateStatus: UNSTABLE`
and required admin-merge despite content being correct. The pattern looks like
flakiness because:

- M1's targeted 23-class pre-push gate runs clean.
- Individual failing tests pass when run in isolation
  (`feedback_wiring_suite_test_isolation.md`, historical `regression_develop_2026_05_11_evening.md`).
- The same code that was green on 5/27 is red on 5/28.

But the flakes are not random. CI run 26593379677 (PR #1020) shows five
distinct, identifiable failure patterns, every one of which is structural.

### Most damning CI evidence

1. **State residue across tests** — same process, 90 seconds apart:
   ```
   18:27:43  ... numAccounts=100, currentAccountId (from UserDefaults)=null
   18:29:27  ... numAccounts=1150, currentAccountId (from UserDefaults)=urn:uuid:1a110ef6-...
   ```
   One test bulk-loaded 1150 accounts; a later test inherited them.

2. **Async-teardown drift** — a test waited 30 seconds for an event that should
   have fired in milliseconds:
   ```
   Test Case '-[PalaceTests.TokenRefreshOnForegroundTests
   test_ConcurrentForegroundRequests_ProduceOneTokenRefresh]' failed (30.353 seconds).
   ```

3. **Keychain entitlement** — 8 distinct `-34018` (`errSecMissingEntitlement`)
   log lines from `TPPKeychainManager.swift`, including writes that "succeed"
   but persist nothing:
   ```
   Failed to ADD secure values to keychain. This is a known issue when running
   from the debugger. Error: -34018
   ```

4. **Network-stub gap** — OIDC redirect handler logged a production error code
   for a fabricated test URL:
   ```
   Sign-in redirection error: missing payload Code=314
   loginURL=palace-oidc-callback://...?access_token=tok&patron_info=%7B%7D
   ```
   The stub never matched; the redirect fell through to real handling.

5. **Xcode 26.3 actor-isolation churn** — every full build emits notes like:
   ```
   conformance of 'CarPlayTemplateManager' to protocol 'CPNowPlayingTemplateObserver'
   crosses into main actor-isolated code and can cause data races; this is an
   error in the Swift 6 language mode
   ```
   plus identical findings on `HoldsViewModel`, `AccountDetailViewModel`, and the
   audiobook toolkit's `LCPStreamingPlayer` / `LCPResourceLoaderDelegate`.

## Categories (six, MECE)

### A. Singleton / global-state residue
Real singletons (`TPPUserAccount.shared`, `AccountsManager.shared`,
`AccountStateStore.shared`, `AppContainer.production()`, `UserDefaults.standard`,
`NotificationCenter.default`) mutated by one test and unread by the next test's
setUp. Distinct from B because the leak is state, not lifecycle.

### B. Async / Combine teardown leakage
Tasks and Combine subscriptions started in tests but not joined/cancelled in
tearDown. Distinct from A because the leak is a still-running event source,
not stale data. Sleep-based waits (`Task.sleep`/`Thread.sleep`, 63 files) fall
here.

### C. Keychain entitlement
`SecItemAdd`/`SecItemCopyMatching` return -34018 on GitHub Actions iOS sim hosts
because the runner has no `keychain-access-groups` entitlement. Tests that use
real `TPPUserAccount` without `KeychainAvailability.skipIfUnavailable()` get
nil-back and fail in confusing downstream places. Distinct from D because it's
an environmental cert/entitlement issue, not a stub issue.

### D. Network-stub race
`HTTPStubURLProtocol`-based stubs that don't tear down cleanly, or that mix
`URLSession.stubbedSession()` with code paths that fall through to
`URLSession.shared` / `TPPNetworkExecutor.shared`. Distinct from B because the
race is in the URLProtocol registry, not the Task lifecycle.

### E. Xcode 26.3 actor-isolation tightening
Class-level `@MainActor` conformances to Apple's nonisolated protocols
(`MFMailComposeViewControllerDelegate`, `Identifiable` on a class, CarPlay
observers, URLSession delegates). Today: build notes that pollute triage.
Tomorrow (Swift 6): errors. Distinct from all other categories because it's a
build-warning class, not a runtime-flake class.

### F. Suite-ordering amplifier
Both Xcode schemes have `testExecutionOrdering = "random"`. This does not CAUSE
flakes; it AMPLIFIES A-D. M1's 23-class subset stays below the residue threshold
and passes clean. The full 485-class suite hits it under random ordering. F is
treated as a distinct category because the FIX shape (CI seeding, observation
seam, in-isolation rerun) is structurally different from A-D's per-test fixes.

## Parallelism plan

All six investigators run **in parallel**. No sequential dependencies — they
operate on disjoint codebase queries:

```
Wave 1 (parallel, all six):
  A: singleton-residue       → PalaceTests/Accounts/, ViewModels/, MyBooks/, SignInLogic/, Integration/, Chaos/
  B: async-combine-teardown  → PalaceTests/Contract/, Audiobooks/, MyBooks/, CarPlay/, Integration/
  C: keychain-entitlement    → PalaceTests/Accounts/, Book/, Chaos/, MyBooks/, SignInLogic/
  D: network-stub-race       → 33 files that import HTTPStubURLProtocol
  E: actor-isolation         → Palace/CarPlay/, Settings/, Holds/, Logging/, SignInLogic/, ios-audiobooktoolkit/
  F: suite-ordering          → Palace.xcodeproj/, PalaceTestSetup.swift, scripts/verify-pr.sh
```

Each investigator returns a finding count, a file:line table, and a fix-shape
section. The orchestrator (this swarm's integrator) cross-references A-D
findings against F's amplifier analysis and produces a unified permanent-fix
plan as the swarm's final artifact.

## Acceptance criteria for the unified plan

The integrated report MUST include:

1. **Per-category finding counts** with severity bucketing (HIGH/MED/LOW).
2. **Top-20 highest-severity findings across all categories** — single sortable list.
3. **Structural fix proposals** (base classes, lint scripts, CI gates) — NOT
   per-test fixes. The point is to make the flake CLASS structurally impossible
   to reintroduce, not to fix the current instances.
4. **Sequencing** — which structural fix lands first (likely C: keychain guard
   coverage, because it's a single-script lint and has the cleanest evidence).
5. **A "stop-the-bleeding" patch list** — the 5-10 specific test files that
   would, if fixed now, restore the develop green state. This is separate from
   the permanent fix; the integrator decides whether to ship it.
6. **A re-flake-prevention checklist** for new test PRs (paste into CLAUDE.md
   TDD section).
7. **Wall-failure entry stubs** — one per category, prepopulated for
   `.forgeos/wall-failures/`, so each category's lesson becomes a permanent
   improvement per the existing wall-failure protocol.

## Risks (what the architect might have miscategorized)

- **A/D overlap on "AppContainer leaks the test's URLSession"**: a test that
  swaps `AppContainer.production().urlSession` for a stubbed session and
  doesn't restore it is BOTH a singleton residue (A) AND a stub-teardown issue
  (D). Investigator A and D may double-count; the integrator must dedup.
- **B/F overlap on Task ordering**: a Task that mutates a singleton mid-tearDown
  is "B teardown leak" causing "A state residue" amplified by "F random
  ordering." Triple-counted unless deduped.
- **E may be over-scoped**: the audiobook-toolkit Sendable warnings are in a
  submodule (`ios-audiobooktoolkit/`) whose changes go through a separate PR
  pipeline. Investigator E should NOTE them but cleanly separate Palace/ from
  ios-audiobooktoolkit/ in the output.
- **G/H were merged into A/B**: simulator state (timezone, locale, booted
  state) has no CI evidence in the run snapshots; date-now timing flakes
  similarly absent. If an investigator surfaces incidental evidence, they
  flag it without re-opening the category.
- **The wiring-test mitigation (`skipBackgroundLoadCatalogs`) already exists**
  at `Palace/Accounts/Library/AccountsManager.swift:157`. Investigator A
  should treat this as a coverage-not-capability gap — the opt-out is the
  fix shape; only enumeration of WHICH tests need to adopt it is in scope.

## Out of scope (firmly)

- No production-code edits (Palace/, ios-audiobooktoolkit/).
- No test-file edits (PalaceTests/).
- No scheme/xctestplan edits (Palace.xcodeproj/).
- No DI refactor proposals beyond flagging "this is where DI would land."
- No Swift 6 mode enablement decision — Investigator E flags blockers; the
  integrator does not advocate for/against the language-mode switch.
- No simdrive / UI test changes — flake investigation is unit-test only.
