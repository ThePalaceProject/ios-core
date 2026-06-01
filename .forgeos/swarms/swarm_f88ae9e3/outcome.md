# swarm_f88ae9e3 — iOS Test Flakiness Permanent-Fix Plan

**Mode:** investigation_only. **Output:** plan, not implementation. Pause for user review before any code lands.

## TL;DR

**The single architectural smoking gun:** `Palace/AppInfrastructure/AppContainer.swift:223` — `static let _cached: AppContainer = { ... AccountsManager() ... }()` constructs the process-wide `AccountsManager` **without** flipping `deferInitialLoadCatalogsForTesting`. Its background `loadCatalogs()` (`Palace/Accounts/Library/AccountsManager.swift:213`) spawns once at first AppContainer access and never gets cancelled. This drives the CI `numAccounts=100 → 1150` 90-second drift exactly. The opt-out flag EXISTS but is adopted by **1 of 25 `AccountsManager()` construction sites in tests** (only `AccountsManagerStateMachineWiringTests`).

**The single highest-leverage architectural seam:** extend `PalaceTests/PalaceTestSetup.swift` with an `XCTestObservation` that, in `testCaseDidFinish(_:)`, resets the registered singletons + drains Combine cancellables + clears the `HTTPStubURLProtocol` handler registry + nukes UserDefaults test keys + checks for orphan NotificationCenter observers. **One file change closes A's blast radius, neutralizes D's process-global LIFO race, and recovers B's leaked SpyDelegate Tasks** — without touching any test method, any production code, the scheme XML, or the CI workflow.

**The biggest correction to the architect's framing:** the 30-second `TokenRefreshOnForegroundTests` timeout is **D amplified by F, not B**. Root cause is `HTTPStubURLProtocol.startLoading`'s `_ = releaseGate.wait(timeout: 3.0)` blocking the URLSession delegate queue per request under random-order test contention. B's Task lifecycle is fine; the delegate queue is the choke point.

---

## Architect corrections from investigators

| Architect claim | Investigator correction |
|----|----|
| OIDC `Code=314` log lines = stub fall-through (D) | **D:** Red herring. `Code=314` is expected log noise from intentional negative tests (`testRegression_handleRedirectURL_rejectsCustomSchemeURL`, `TPPSignInBusinessLogicOAuthTests:224,266`). Pure URL-string prefix matching, no HTTPStub involved. |
| 30s `TokenRefresh` failure = async/Combine teardown leak (B) | **B+D:** B's Tasks are clean. Root cause is `HTTPStubURLProtocol.startLoading`'s 3s `releaseGate.wait()` blocking the URLSession delegate queue. Reclassify as **D amplified by F**. |
| 485 XCTestCase classes | **F:** 798 classes / ~7,022 methods / 529 files. 31% of test files touch `.shared` singletons. |
| Both Xcode schemes use `testExecutionOrdering = "random"` | **F:** Only `Palace.xcscheme` is random. `Palace-noDRM.xcscheme` lacks the attribute entirely → Xcode default ordering. Explains noDRM's historically lower flake rate. |
| `AccountsManager.skipBackgroundLoadCatalogs` already mitigates A | **A:** Opt-out EXISTS but adopted by **1 of 25** construction sites. `AppContainer._cached` itself spawns the leak. Surface is wide open. |
| Combine cancellable leakage is a real category (B) | **B:** False alarm. 48 files all drain `cancellables` correctly. |
| CI runs `verify-pr.sh --quick` | **F:** CI calls `scripts/xcode-test-optimized.sh` directly. The `--diff-baseline` rerun-in-isolation logic is local-only. |

---

## Findings by category (counts + severity)

| Cat | What | HIGH | MED | LOW | Transcript |
|----|----|---|---|---|----|
| **A** singleton residue | Process-wide singletons mutated by tests, no reset | 14 | 5 | ~85 (DI debt) | A-singleton-residue.md (138L) |
| **B** async/Combine teardown | Unjoined Tasks in SpyDelegates; `waitForCondition` polling | 5 | 3 | 168 sleep sites | B-async-combine-teardown.md (616L) |
| **C** keychain entitlement | `KeychainAvailability` guard exists, adopted by 0/9 risk files | 4 | 5 | 4 false-positive grep matches | C-keychain-entitlement.md (347L) |
| **D** network stub race | `HTTPStubURLProtocol.canInit→true` + process-wide singleton + 3s delegate block | 4 | 4 | 5 `URLSession.shared` prod sites | D-network-stub-race.md (243L) |
| **E** actor isolation (Xcode 26.3) | `@MainActor` classes vs nonisolated Apple protocols | 4 files / 13 warnings | 5 test mirrors | ios-audiobooktoolkit/ (~30L noise) | E-actor-isolation-xcode-26-3.md (205L) |
| **F** suite ordering amplifier | `Palace.xcscheme` random; `Palace-noDRM` not; 0 XCTestObservation hooks | structural | structural | — | F-suite-ordering-amplifier.md (349L) |

---

## Top-20 highest-severity findings (sorted by leverage)

| # | Cat | File:line | What | Why blocks fix |
|---|---|---|---|---|
| 1 | A | `Palace/AppInfrastructure/AppContainer.swift:223` | `static let _cached` AccountsManager() w/o test opt-out spawns background `loadCatalogs()` for process lifetime | Drives `numAccounts=100→1150` drift. Single biggest architectural source. |
| 2 | D | `PalaceTests/Mocks/HTTPStubURLProtocol.swift:13-15` | `canInit → true` ALWAYS once registered; intercepts every `URLSession.shared` request globally, returns 501 for unmatched | Causes silent fall-through to 501 across unrelated tests. |
| 3 | D | `PalaceTests/Mocks/HTTPStubURLProtocol.swift` (startLoading) | `_ = releaseGate.wait(timeout: 3.0)` BLOCKS URLSession delegate queue per request | Smoking gun for 30s `TokenRefreshOnForegroundTests` timeout. |
| 4 | F | `Palace.xcodeproj/.../xcshareddata/xcschemes/Palace.xcscheme` | `testExecutionOrdering = "random"` (Palace only; not Palace-noDRM) | Random order amplifies A/B/C/D residue; no XCTestObservation reset. |
| 5 | F | `PalaceTests/PalaceTestSetup.swift` | Bootstrap fires `NoNetworkURLProtocol.enable()` only; 12 LOC; **no XCTestObservation seam** | Right vehicle, wrong payload. The fix landing pad. |
| 6 | F | `.github/workflows/unit-testing.yml:98` | CI invokes `scripts/xcode-test-optimized.sh` directly; bypasses `verify-pr.sh` | `--diff-baseline` rerun-in-isolation never runs in CI. |
| 7 | A | `PalaceTests/Integration/{SignInToReadFlow, BorrowAndDownload, AccountSwitchLifecycle, ColdStartResume}IntegrationTests.swift` | Raw `AccountsManager()` w/o opt-out in setUp | 4 integration tests each spawning a background loadCatalogs Task. |
| 8 | A | `PalaceTests/BookRegistry/TPPBookRegistry{Persistence,AtomicWrite,LargeCorpus,Migration,Dependency}Tests.swift` | 5 more raw `AccountsManager()` constructions; some inline mid-test | 5 BookRegistry tests, same leak as #7. |
| 9 | A | `PalaceTests/ViewModels/AccountDetailViewModelTests.swift:466,496,527,552,581,609,637,929,948,1044,1118` | 11 `account.setBarcode/setAuthToken/setAuthState` mutations on real per-library `TPPUserAccount`; cleanup only in happy path | Each unique libraryID permanently grows `AccountsManager.userAccounts[...]`. |
| 10 | A | `PalaceTests/Accounts/AccountSwitchCleanupTests.swift:104-142` | No setUp/tearDown class; 50-distinct-UUID loop allocates permanent singleton entries | `userAccounts` dictionary grows monotonically per run. |
| 11 | C | `PalaceTests/TPPBookBearerTokenTests.swift` | 8 unguarded keychain writes; homegrown duplicate `isKeychainAccessible` probe (lines 24-39) | Fails opaquely on CI's -34018 host; should adopt `KeychainAvailability`. |
| 12 | C | `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` | 10 real `.sharedAccount(libraryUUID:)` calls; no guard | Combined HIGH on both A (#10) and C — single seam fixes both. |
| 13 | B | `PalaceTests/SignInLogic/TokenRefreshOnForegroundTests.swift:417-429,250` + `TokenRefreshAndRetryQueueTests:449` | `waitForCondition(timeout: 30.0)` running `RunLoop.current.run(...)` for an event arriving via actor-hop + URLSession callback | Three tests same bug. Amplified by #3 (D). |
| 14 | B | `PalaceTests/{BorrowOperation, BookReturnCleverReauth, DownloadAuthRetryHandler}*Tests.swift` SpyDelegates | `Task { @MainActor in self.X.append(...) }` unjoined; 4 sites | Tasks bleed into next test's MainActor queue. |
| 15 | B | `PalaceTests/DRMAdversarialTests.swift:106` | `Task { XCTFail(...) }` unjoined | Test structurally cannot fail. |
| 16 | A | `PalaceTests/AudiobookTrackerTests.swift:535` + `Chaos/ChaosHarness.swift:196` | App-lifecycle broadcasts (`UIApplication.willTerminateNotification`, `didReceiveMemoryWarningNotification`) via `NotificationCenter.default.post` | Production observers (Crashlytics flush, ImageCache evict, BookCellModelCache flush) react across test boundaries. |
| 17 | A | 13 test files post `NotificationCenter.default.post(name: .TPP*)` | 7 production observers consume: `TPPBookRegistry:126`, `BookCellModelCache:126`, `AccountDetailViewModel:199`, `HoldsViewModel:129`, `CarPlaySceneDelegate:182`, `CatalogView:38`, `DLNavigator:74` | Side-effect residue through production observer code paths. |
| 18 | E | `Palace/Settings/AccountDetailViewModel.swift` (4 protocols) | `@MainActor` class vs nonisolated `NYPLUserAccountInputProvider`, `TPPSignInOutBusinessLogicUIDelegate`, `TPPSignInBusinessLogicUIDelegate`, `NYPLBasicAuthCredentialsProvider` | Single file produces ~16 of the 113 CI noise lines per build. |
| 19 | E | `Palace/Logging/ErrorLogExporter.swift` (MFMailComposeViewControllerDelegate) | `@MainActor` class vs Apple-owned nonisolated delegate | Tier 2 fix: drop `@MainActor` on class, wrap UI body in `Task { @MainActor in }`. |
| 20 | E | `Palace/Holds/HoldsViewModel.swift` (HoldsBookViewModel.id Identifiable) + `Palace/CarPlay/CarPlayTemplateManager.swift` (CPNowPlayingTemplateObserver) | Tier 1 trivial: `nonisolated` on `id`; `nonisolated` + main-actor hop on CarPlay observer methods | ~8 lines of noise eliminated cheaply. |

---

## Cross-cutting structural fixes (ranked by leverage)

### Fix 1: `PalaceTestSetup` + `XCTestObservation` reset hook
**Files touched:** `PalaceTests/PalaceTestSetup.swift` (extend existing 12-LOC bootstrap).
**Closes:** A blast radius, D process-global state, B SpyDelegate leak (partial).
**Shape:** add `XCTestObservation.testCaseDidFinish(_:)` that:
1. Calls a registry of `() -> Void` resetters: `AccountStateStore._resetAllForTesting()`, `AccountsManager._resetCachedAccountsManager()` (new DEBUG-only seam), `TPPUserAccountMock.resetShared()`, `HTTPStubURLProtocol.removeAllHandlers()`, `URLSession.stubbedSession()._reset()`.
2. Audits `NotificationCenter.default` observer count delta (warn if increased without removal).
3. Clears UserDefaults test keys (whitelist).
4. Asserts `cancellables` registry empty for `AsyncTestCase` users.
**Adoption cost:** zero per-test changes — observer is process-wide.

### Fix 2: `AccountsManager._resetCachedAccountsManager()` DEBUG-only seam in AppContainer
**Files touched:** `Palace/AppInfrastructure/AppContainer.swift` (add `#if DEBUG` static func), `Palace/Accounts/Library/AccountsManager.swift` (no changes — opt-out already exists).
**Closes:** root of A.
**Shape:** single `internal static func _resetForTesting()` that re-initializes `_cached` with `deferInitialLoadCatalogsForTesting = true`. NOT a DI refactor — one function, ~20 LOC. Called by Fix 1.

### Fix 3: `HTTPStubURLProtocol` restructure
**Files touched:** `PalaceTests/Mocks/HTTPStubURLProtocol.swift`, `PalaceTests/Mocks/URLSession+Stubbing.swift`.
**Closes:** root of D + amplification of B's 30s timeout.
**Shape:**
1. `canInit(with:)` narrows to URL-predicate match (handler registry indexes by URL pattern; return false when no match → request falls through to `NoNetworkURLProtocol` cleanly).
2. Drop the process-wide `URLSession.stubbedSession()` singleton; provide a per-call factory `URLSession.stubbed(handlers: [Handler])`.
3. Replace 3s `releaseGate.wait()` with `DispatchQueue` async completion — no delegate queue block.
**Adoption cost:** 33 file migration; mechanical. Consider `HTTPStubTestCase` base for the 27 files that use the class-level register/unregister pattern.

### Fix 4: Lint suite gated in `verify-pr.sh` AND `xcode-test-optimized.sh`
**Files touched:** `scripts/check-singleton-leaks.py`, `scripts/check-keychain-guard-coverage.py`, `scripts/check-stub-discipline.py`, `scripts/check-sleep-in-tests.py`, `scripts/check-protocol-isolation.py` (NEW); `scripts/verify-pr.sh` + `scripts/xcode-test-optimized.sh` (wire).
**Closes:** structural prevention of A, B, C, D, E recurrence.
**Shape:** each script is ~150-300 LOC stdlib-only Python (matches M1's check-test-name-vs-body.py pattern). Fail-closed for NEW offenders (diff-scoped against `origin/develop`); warn-only for pre-existing.

### Fix 5: Two-target scheme parity + CI path consolidation
**Files touched:** `Palace.xcodeproj/.../Palace-noDRM.xcscheme` (add `testExecutionOrdering`), `.github/workflows/unit-testing.yml` (call `verify-pr.sh --quick` instead of `xcode-test-optimized.sh` directly; or port `--diff-baseline` rerun into the latter).
**Closes:** F.
**Shape:** alignment work; no new infra. Decision: after Fix 1+3 settle for ≥1 week, flip both schemes to `alphabetical` for full determinism (Fix F's option (i)).

### Fix 6: Actor-isolation Tier 1+2 cleanup
**Files touched:** `HoldsBookViewModel.id` (1 line), CarPlayTemplateManager observer methods, `AccountDetailViewModel` protocols (annotate at definition), `ErrorLogExporter` (restructure mail composer delegate).
**Closes:** ~36 of 113 CI noise lines.
**Shape:** mechanical for Tier 1+2; Tier 3 `NYPLBasicAuthCredentialsProvider` deferred as a separate architectural decision.

### Fix 7 (DEFERRED — not in scope of this swarm): `AsyncTestCase` + `KeychainBackedTestCase` base classes
Adoption requires touching test methods. Fix 1 captures most of the wins. Land these only if Fix 1 + Fix 3 don't restore green.

---

## Sequencing

| Order | Fix | Effort | Risk | Why first |
|----|----|----|----|----|
| 1 | **Fix 1** (PalaceTestSetup XCTestObservation) | M | LOW | Single file. Closes A+D blast radius without per-test edits. Verify on local suite before CI push. |
| 1 | **Fix 2** (AppContainer `_resetForTesting`) | S | LOW | Required by Fix 1's resetter registry. ~20 LOC. |
| 2 | **Fix 3** (HTTPStubURLProtocol restructure) | L | MED | Fixes D's structural race + B's 30s amplification. Migration touches 33 files mechanically. Land after Fix 1 stabilizes. |
| 3 | **Fix 4** (lint suite) | M | LOW | Prevents regression. Wire as warn-only first, flip to block after one PR cycle of cleanup. |
| 4 | **Fix 6** (actor-iso Tier 1+2) | M | LOW | Pure noise reduction; recovers triage signal. Can land in parallel with Fix 3. |
| 5 | **Fix 5** (CI path + scheme parity) | S | LOW | Final consolidation; only after the above prove out. |

---

## Stop-the-bleeding patch list (5-10 specific files for an interim "make develop green" PR)

If the user wants develop green **now** without the full structural plan, the following targeted patches close the documented CI failures:

| # | File | Change | Why |
|---|---|---|---|
| SB-1 | `Palace/AppInfrastructure/AppContainer.swift:223` | Wrap `_cached` init in `#if DEBUG` that flips `deferInitialLoadCatalogsForTesting = true` when `ProcessInfo.processInfo.arguments.contains("-XCTRunUnderXCTest")` | Closes finding #1 directly. |
| SB-2 | `PalaceTests/Mocks/HTTPStubURLProtocol.swift` | Remove `releaseGate.wait(timeout: 3.0)`; replace with non-blocking completion via `DispatchQueue.global().async` | Closes finding #3 directly — the 30s `TokenRefresh` timeout. |
| SB-3 | `PalaceTests/SignInLogic/TokenRefreshOnForegroundTests.swift:417-429,250` + `TokenRefreshAndRetryQueueTests:449` | Replace `waitForCondition` with `await fulfillment(of: [expectation], timeout: 5.0)` | Closes finding #13 directly. |
| SB-4 | `PalaceTests/TPPBookBearerTokenTests.swift:24-39` | Replace homegrown `isKeychainAccessible` with `try KeychainAvailability.skipIfUnavailable()` in `setUpWithError` | Closes finding #11. |
| SB-5 | `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` | Add `setUpWithError` with `KeychainAvailability.skipIfUnavailable()` + `AccountStateStore.shared._resetAllForTesting()` | Closes findings #10 + #12 (A + C). |
| SB-6 | `Palace/Holds/HoldsViewModel.swift` (HoldsBookViewModel.id) | Add `nonisolated` qualifier | Eliminates 4 CI noise lines. |
| SB-7 | `Palace/CarPlay/CarPlayTemplateManager.swift` (CPNowPlayingTemplateObserver methods) | Add `nonisolated` + main-actor hop | Eliminates 4 CI noise lines. |
| SB-8 | `PalaceTests/{BorrowOperation, BookReturnCleverReauth, DownloadAuthRetryHandler}*Tests.swift` SpyDelegates | Replace `Task { @MainActor in self.X.append(...) }` with synchronous `MainActor.assumeIsolated { ... }` or use existing `CallLog` | Closes finding #14. |
| SB-9 | `PalaceTests/DRMAdversarialTests.swift:106` | Replace `Task { XCTFail(...) }` with `await MainActor.run { XCTFail(...) }` | Closes finding #15. |
| SB-10 | `Palace.xcodeproj/.../Palace-noDRM.xcscheme` | Add `testExecutionOrdering = "random"` to match Palace.xcscheme (OR remove it from Palace.xcscheme — decision required) | Closes finding #4 by aligning the two schemes. |

**Risk:** SB-1 changes a process-wide AccountsManager behavior under XCTest. Test-suite-only; cannot affect production. SB-2 is the highest-blast-radius change — vet against the few tests that may rely on the gate (audit `grep -rn "releaseGate" PalaceTests/`).

---

## Re-flake-prevention checklist (paste into CLAUDE.md "TDD & Test Quality" section)

```markdown
### New-test-PR flake-prevention checklist

Every test file added or modified must:

1. **Inherit from `PalaceSingletonTestCase`** (or document an `// allow-real-singletons: <reason>` comment if intentional).
2. **NEVER construct `AccountsManager()` directly** without the `deferInitialLoadCatalogsForTesting` opt-out. Use `Mock` or accept an injected instance.
3. **NEVER call `URLSession.shared` or `URLSession.stubbedSession()` in production code paths under test** — use the per-call `URLSession.stubbed(handlers:)` factory.
4. **NEVER use `Task.sleep`, `Thread.sleep`, or `waitForCondition`** — use `fulfillment(of: [...], timeout: 5.0)`.
5. **For keychain-touching tests**: inherit `KeychainBackedTestCase` OR call `try KeychainAvailability.skipIfUnavailable()` in `setUpWithError`.
6. **For NotificationCenter posts**: route through an injected `NotificationCenter` (not `.default`) unless the test explicitly exercises a production observer.
7. **SpyDelegates must not fire unjoined `Task { ... }`** — use the project's thread-safe `CallLog` (`PalaceTests/Contract/CallLog.swift`).
8. **Run `python3 scripts/check-singleton-leaks.py --file <test-file>`** before opening PR; exit must be 0.
```

---

## Wall-failure entry stubs (one per category)

The orchestrator should create these under `.forgeos/wall-failures/2026-05-29-flakiness-<cat>.md` after the implementation PR lands:

- `2026-05-29-flakiness-singleton-residue.md` — wall that should have caught: pre-commit lint + test isolation harness. Permanent fix: Fix 1+2+4 above.
- `2026-05-29-flakiness-async-task-leak.md` — wall: lint for unjoined `Task {}` in SpyDelegates; `addTestTask` registration. Permanent fix: Fix 4 (sleep-allowlist + `Task {}` scanner).
- `2026-05-29-flakiness-keychain-guard.md` — wall: `check-keychain-guard-coverage.py` (Fix 4). Permanent fix: guard adoption + base class.
- `2026-05-29-flakiness-stub-race.md` — wall: `HTTPStubURLProtocol.canInit` predicate narrowing + per-call URLSession factory. Permanent fix: Fix 3.
- `2026-05-29-flakiness-actor-iso-noise.md` — wall: diff-scoped `verify-pr.sh` gate on NEW "cannot satisfy nonisolated requirement" notes. Permanent fix: Fix 4 (`check-protocol-isolation.py`) + Fix 6.
- `2026-05-29-flakiness-suite-ordering.md` — wall: scheme-parity audit + XCTestObservation seam. Permanent fix: Fix 1 + Fix 5.

---

## Outstanding architect risks resolved

| Architect risk | Outcome |
|----|----|
| A/D overlap on "AppContainer leaks the test's URLSession" | NOT FOUND. D verified no tests mutate `AppContainer.production().networkExecutor.session`. No dedup needed. |
| B/F overlap on Task ordering | Re-classified: B's Task structure is correct; the failure is **D-amplified-by-F**. Fix lives in Fix 3, not B. |
| E over-scoped vs ios-audiobooktoolkit | E correctly separated. Palace/ findings actionable (Fix 6); toolkit findings (~30 lines noise) deferred to submodule PR pipeline. |
| G/H merged into A/B | No incidental evidence surfaced for simulator state (G) or time-dependent code (H). Stays merged. |
| Wiring-test mitigation already exists | Confirmed: opt-out exists; adopted by 1 of 25 sites. Coverage gap is the actual issue. |

---

## What needs your decision before implementation lands

1. **Stop-the-bleeding patch (SB-1..SB-10) vs full structural fix first?** Stop-the-bleeding makes develop green in ~1 PR (~100 LOC). Structural fix is 5 PRs landing over 1-2 weeks. Hybrid possible.
2. **Fix 5: `Palace-noDRM` scheme — add `testExecutionOrdering="random"` (parity) or remove from Palace (uniform default ordering)?** Recommend: remove from Palace; leverage Fix 1's reset hook to make ordering immaterial.
3. **Fix 3 migration scope.** 33 files. Mechanical but visible diff. PR splittable into "core stub class restructure" + "test file migration sweep." User preference?
4. **Tier 3 actor-isolation: `NYPLBasicAuthCredentialsProvider`.** Real architectural decision (DI getter pattern vs companion type). Defer as standalone ticket.
5. **Implementation as a /swarm? Or single-agent?** This swarm produced a unified plan. Implementation touches ≥3 modules (SignInLogic, AppInfrastructure, MyBooks, test infra) — formally /swarm territory. But each fix is well-scoped; could be 4-5 sequential single-agent PRs. User preference?

---

## Definition of Done (swarm-orchestrator-scoped)

- [x] All 6 investigator transcripts written and read
- [x] Architect corrections enumerated (8 items)
- [x] Top-20 findings sorted across categories
- [x] 6 structural fixes proposed with sequencing
- [x] Stop-the-bleeding patch list (10 files)
- [x] CLAUDE.md re-flake-prevention checklist drafted
- [x] Wall-failure entry stubs (6) outlined
- [x] Architect risks resolved (5 items)
- [x] No production-code or test-file changes — `git status` shows only `.forgeos/swarms/swarm_f88ae9e3/` writes
- [ ] **User review** (blocking — Phase 5 implementation deferred to user approval)
