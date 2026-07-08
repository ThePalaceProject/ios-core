---
name: swarm_9d3d2fab-transcript-module-c-accounts-signin
type: ephemeral
status: active
created: 2026-05-21
last_refresh: 2026-05-22
freshness_window: 180d
owners: [signin-modal]
description: Module C — Accounts/SignIn (CI-flake migration)
---

# Module C — Accounts/SignIn (CI-flake migration)

## Scope (8 files)

| File | Violations migrated |
|------|---------------------|
| PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift | 2× FLAKE-001 + 7× FLAKE-002 |
| PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift | 1× FLAKE-003 (timeout dropped) |
| PalaceTests/Accounts/UserAccountPublisherTests.swift | 1× FLAKE-003 (OK-marked) |
| PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift | 1× FLAKE-002 |
| PalaceTests/SignInLogic/TPPSignInBusinessLogicSignOutTests.swift | 1× FLAKE-002 |
| PalaceTests/SignInLogic/LegacySAMLProblemDocumentPropagationTests.swift | 1× FLAKE-002 |
| PalaceTests/SignInLogic/TPPAgeCheckDeepTests.swift | 1× FLAKE-003 (OK-marked) |
| PalaceTests/SignInLogic/SignInWebSheetIntegrationTests.swift | 2× FLAKE-003 (OK-marked) |

Detected total: 9× FLAKE-002 (contract listed 7; the linter surfaced 2 extra
sites at AccountsManagerStateMachineWiringTests L697 and SignInWebSheetIntegrationTests
L178 — both migrated). 2× FLAKE-001. 5× FLAKE-003 (4 listed + 1 extra).
Pre-existing FLUFF-001 sites at UserAccountPublisherTests:94 and
TPPSignInBusinessLogicSignOutTests:397 are out of scope (mechanical
flake migration only per plan.md).

## Migration decisions

### AccountsManagerStateMachineWiringTests.swift

**FLAKE-001 polling loops (L334, L747)** — both were
`while Date() < deadline { … Thread.sleep(0.05) }` loops on background queues
waiting for `AccountStateStore.shared.state(for: uuid)` to advance past
`.basicInfoLoaded`. Replaced with `awaitCondition(timeout: 4.0)` that polls
the same predicate. The helper enforces failure-on-timeout (no silent stale
reads) and removes the manual queue-juggling. Net: 22 lines of looping
ceremony per site replaced by 8 lines of declarative wait.

**FLAKE-002 "background settled" waits (L118, L267, L367, L697)** — each
was `DispatchQueue.global().asyncAfter(0.4) { fulfill() }` calling
`AccountsManager()` to let its init-fired background `loadCatalogs()` settle
before `_resetAllForTesting()`. Reviewed the production path: without
network, `fetchFromNetwork` → URLSessionCrawlerFetcher → fast failure, and
the failure branch does NOT write to `AccountStateStore` (only the success
path's `loadAccountSetsAndAuthDoc → preloadAccounts(...)` → `_setState(.basicInfoLoaded)`
writes state). Replaced with two `drainMainQueue()` calls: any
main-thread completion blocks queued by the background's failure handlers
land before the assertion proceeds. Honest documentation of the no-network
contract in the comment.

**FLAKE-002 "stream drain" waits (L423, L495, L603)** — these were
`DispatchQueue.global().asyncAfter(0.05–0.15) { fulfill() }` calls to give
a `Task { for await state in account.stateStream { observed.append(...) } }`
observer time to land its accumulator writes before the assertion reads
`observed`. Two migrations:
- L495 (test 3): the streamTask breaks on `.detailsFailed`, so the writes
  must already have happened. Replaced with `awaitCondition(timeout: 2.0)`
  polling `observed.contains("detailsLoading") && observed.contains(...)`.
  This converts a "hope it's settled" delay into an explicit poll on the
  real signal.
- L423 (test 2c) & L603 (test 4): downstream of "no further emission"
  invariants. Used `drainMainQueue()` — any unwanted Combine emission
  from the SUT would have dispatched through main by the time the no-op
  flushes.

### TPPCredentialIsolationE2ETests.swift L160

500-iteration concurrent Keychain-write test; original `timeout: 30` was
padding around a fast (synchronous) batch. Dropped to `timeout: 5` with
a comment explaining the legacy padding.

### UserAccountPublisherTests.swift L102

Already uses `awaitCondition(timeout: 15.0)` polling `isSigningOut == false`.
The 15s budget is justified inline (Task.sleep(100ms) + main-actor publish
under late-suite contention legitimately needs >5s after ~3,700 prior tests).
Added `// FLAKE-003-OK:` marker with the documented reason.

### TPPSignInBusinessLogicOAuthTests.swift L567

Classic `DispatchQueue.main.asyncAfter(0.2) { drain.fulfill() }` pattern
draining the network executor's main-dispatch completion. Replaced with
`drainMainQueue()` — DispatchQueue.main FIFO contract gives identical
semantics with zero fixed delay.

### TPPSignInBusinessLogicSignOutTests.swift L308

Same drain-main pattern: `asyncAfter(0.3) { drain.fulfill() }` giving a
hypothetical second sign-out a chance to spin up before asserting it was
coalesced. Replaced with `drainMainQueue()`.

### LegacySAMLProblemDocumentPropagationTests.swift L303

Same drain-main pattern: `asyncAfter(0.5) { settled.fulfill() }` giving any
leaked delegate dispatch a chance to land before asserting the live
delegate count is 0. Replaced with `drainMainQueue()`.

### TPPAgeCheckDeepTests.swift L161

`wait(for: [verifyDone], timeout: 30.0)` with extensive inline rationale
explaining the serialQueue chain (verify append → flush → didCompleteAgeCheck
enqueue → handler fanout) under CI runner load. Added `// FLAKE-003-OK:`
marker citing the documented serial-queue chain rationale.

### SignInWebSheetIntegrationTests.swift L106, L178

Both are real WKWebView integration tests with thoroughly documented
30s/15s timeouts (cold-start of WebContent + GPU + Networking helpers
under memory-pressured CI nodes). Added `// FLAKE-003-OK:` markers on
both lines citing the cold-start reason.

## Verification

### Linter (authoritative gate per plan.md acceptance criteria)

```
$ for f in $files; do
    python3 scripts/lint-test-quality.py --per-file --file "$f" | \
      grep -E ":(FLAKE|MISSING)-"
  done
# zero output → all FLAKE-* + MISSING-* violations cleared in scope.
```

Pre-existing FLUFF-001 sites at
- PalaceTests/Accounts/UserAccountPublisherTests.swift:94
- PalaceTests/SignInLogic/TPPSignInBusinessLogicSignOutTests.swift:397

are explicitly out of scope per the Phase 1 plan ("pure migration only,
no new tests, no production code changes").

### Build / test execution

`xcodebuild test` from the worktree blocked by the Palace-worktree symlink
issue documented in MEMORY ("Palace iOS worktrees need manual setup —
symlink Carthage/Build + 8 submodules to main"). With submodule symlinks
in place, the build fails with `Multiple commands produce
.../AudioEngine.framework` because the submodule's pbxproj uses
`../Carthage/Build/AudioEngine.xcframework` which resolves through the
symlink chain to a different absolute path than Palace.xcodeproj's own
`Carthage/Build/AudioEngine.xcframework` reference (both end at the same
file, but Xcode 26 treats them as two ProcessXCFramework input commands).

Parallel module workers (e.g. swarm_9d3d2fab-d) sidestep this by running
their tests against the **main repo's** Palace.xcodeproj at
`/tmp/swarm_9d3d2fab-d-main-test`, which has WorkspacePath
`/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj` (not the
worktree). The auto-mode classifier blocks Module C from doing the same
(it's flagged as scope-escalation since the user's instruction is to
operate from the dedicated worktree).

Compensating evidence for migration correctness:

- **Syntax parse passes for all 8 files** via
  `swift -frontend -parse PalaceTests/.../<File>.swift` — zero errors,
  zero warnings.
- **Mechanical translation** of well-known patterns from
  `PalaceTests/XCTestCase+drainMainQueue.swift`. Every site falls in one
  of three documented categories:
  1. `DispatchQueue.main.asyncAfter + fulfill` → `drainMainQueue()`
     (4 sites: OAuth, SignOut, SAML, plus 3 stream-drain sites).
     FIFO semantics preserve correctness; helper is allow-listed by the
     linter as an assertion-equivalent.
  2. Background polling loops with `Thread.sleep` →
     `awaitCondition(timeout: …)` (2 sites in state-machine tests).
     Predicate matches the original loop's exit condition.
  3. Documented-rationale timeouts ≥15s → add `// FLAKE-003-OK: <reason>`
     (3 sites: UserAccountPublisher, AgeCheck, SignInWebSheet ×2).
- **No production code touched** — `git status` shows only the 8 test
  files modified.

### Risk

Low. The `drainMainQueue` substitution is identical in semantics to the
asyncAfter+fulfill pattern when the dispatched work targets main, plus
faster (no fixed delay). The `awaitCondition` substitution for the
state-store polls replaces a manual `while Date() < deadline` with the
helper's identical polling structure, but with mandatory failure-on-timeout
(catches stuck conditions that the old loops would have silently allowed).
The FLAKE-003-OK markers preserve existing test budgets verbatim.

The 400ms "background settled" → `drainMainQueue()×2` substitution is the
most novel call. Reviewed the production code (`AccountsManager.init`
→ `DispatchQueue.global.async { loadCatalogs() }` → without network,
`fetchFromNetwork` Task fails before any `AccountStateStore` write) to
confirm the wait was strictly defensive padding. If a regression
hypothetically introduces network access in the unit-test env, the
post-drain `_resetAllForTesting()` + explicit `preloadAccountsFromDiskCacheSync()`
sequence is still robust — the background's hypothetical late write
would have to win a race against subsequent sync test code, which is
already a hostile timing assumption.

## Files left untouched (per contract)

- `Palace/Accounts/*`, `Palace/SignInLogic/*` — production code read-only.
- `AccountStateStore` / `TPPUserAccount` singleton refactor — Phase 2.
- Two FLUFF-001 sites — pre-existing, mechanical-migration only.

## Git state

Working tree clean except for the 8 in-scope test files:

```
 M PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift
 M PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift
 M PalaceTests/Accounts/UserAccountPublisherTests.swift
 M PalaceTests/SignInLogic/LegacySAMLProblemDocumentPropagationTests.swift
 M PalaceTests/SignInLogic/SignInWebSheetIntegrationTests.swift
 M PalaceTests/SignInLogic/TPPAgeCheckDeepTests.swift
 M PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift
 M PalaceTests/SignInLogic/TPPSignInBusinessLogicSignOutTests.swift
```

Diff stat: 13 files changed, 72 insertions(+), 86 deletions(-).
(13 includes 5 submodule placeholder type-changes that have been
restored to empty directories prior to handoff — they no longer show in
status.)

No commit, no push, per workflow instructions. Integrator picks up from
here for `verify-pr.sh --quick` + `forge-review`.
