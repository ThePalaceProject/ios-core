---
name: swarm fire and forget task cleanup
author: maurice.carrier
swarm_id: swarm_4e47d4d4
parent_swarms: [swarm_47883816, swarm_5b500284, swarm_cd181acd]
created: 2026-06-04
type: refactor
risk: critical_path
---

# Fire-and-forget Task cleanup — drain F-audit findings from swarm_47883816

## Motivation

Per `.forgeos/swarms/swarm_47883816/transcripts/F-audit.md`, the parent swarm's F-implementer identified 5 fire-and-forget Task findings:

**Test-side (2):**
- F-iii-1: `PalaceTests/Security/DRMAdversarialTests.swift:106` — `Task { ... XCTFail }` never awaited + tautology `XCTAssertTrue(true)`
- F-iii-2: `PalaceTests/Logging/PersistentLoggerTests.swift:26` — `tearDown()` launches Task that's never awaited, leaks log dir + actor reference

**Production-side critical-path (3):**
- F-iii'-1: `Palace/MyBooks/DownloadAuthRetryHandler.swift` — 8 fire-and-forget `Task { [weak self] in ... }` launches without retention/cancellation
- F-iii'-2: `Palace/MyBooks/BookReturnService.swift` — fire-and-forget Tasks (OPDS fetch + cleanup hops) requiring test-side poll-wait
- F-iii'-3: `Palace/SignInLogic/` or `Palace/Accounts/` — `signOut()` 100ms reset Task via `Task { Task.sleep(100ms); isSigningOut = false }`

Each is a real risk for cross-test state pollution and (for production) for state leaking past user-visible operations.

## Claims (what the diff WILL deliver)

1. **DRMAdversarialTests**: replace the fire-and-forget Task + tautology with a proper `async throws` test that asserts against the expected thrown error type.

2. **PersistentLoggerTests**: migrate `tearDown()` → `tearDown() async throws` and await the cleanup Task.

3. **DownloadAuthRetryHandler**: retain the 8 Tasks via a `Set<Task<Void, Never>>` or `[Task]` property; cancel them in deinit AND when the handler is reset. Add explicit test verifying Tasks are cancelled when the handler dies.

4. **BookReturnService**: retain Tasks via Set<Task>; cancel on deinit/reset; tests use the cancellation signal rather than poll-wait.

5. **signOut 100ms Task**: retain the reset Task as a property; cancel it if signOut is called again before the 100ms elapses; tests can await it deterministically.

## Anti-claims

- Does NOT change observable production behavior — only adds Task retention + cancellation semantics. The 100ms delay before `isSigningOut = false` continues to behave the same in the happy path.
- Does NOT introduce new public API on production classes (cancellable properties are internal/private).
- Does NOT modify the existing test-side `awaitConditionAsync` / `waitForAsyncCleanup` helpers (they continue to work; the new cancellation semantics are additive).

## Files in scope

**Test target:**
- `PalaceTests/Security/DRMAdversarialTests.swift`
- `PalaceTests/Logging/PersistentLoggerTests.swift`

**Production (critical-path — needs architect rigor):**
- `Palace/MyBooks/DownloadAuthRetryHandler.swift`
- `Palace/MyBooks/BookReturnService.swift`
- One of: `Palace/SignInLogic/TPPSignInBusinessLogic.swift`, `Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift`, or `Palace/Accounts/...` (implementer to identify exact location of the 100ms Task)

**Tests (new + updated):**
- New test in `PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift` verifying Task cancellation
- New test for BookReturnService Task lifecycle
- New test for signOut Task deterministic cancellation
- DRMAdversarialTests + PersistentLoggerTests rewritten

## Risk

**Critical path.** Three of the five fixes touch `Palace/MyBooks/Download*`, `Palace/MyBooks/BookReturn*`, and `Palace/SignInLogic/`. Per CLAUDE.md these REQUIRE architect rigor + mutation testing.

## Verification

- Mutation kill rate ≥50% on each critical-path file diff (`palace_mutate.py --diff-only`).
- All new + updated tests PASS.
- `xcodebuild build` clean.
- All 5 DoD scripts exit 0.
- F-audit findings categorized as "FLAGGED" should be removable from a follow-up audit pass.
