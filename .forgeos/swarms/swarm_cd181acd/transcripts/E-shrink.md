# E-shrink — TearDownRequiredLintTests baseline drain

**Implementer:** E-shrink (swarm_cd181acd)
**Date:** 2026-06-04
**Workspace:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_cd181acd-orchestrator`
**Sim:** `141BD227-6E9A-4409-8D99-2D4FE818238D` (iPhone 16 Pro)
**DerivedDataPath:** `/tmp/swarm_cd181acd_E`

## Scope

Drain the 37-entry `.forgeos/swarms/swarm_47883816/E-teardown-baseline.txt` by adding minimal `override func tearDown()` (or `tearDownWithError`) overrides to each XCTestCase-derived file so the `TearDownRequiredLintTests` structural lint can recognise them as compliant.

## Outcome — files cleared (36) + already-compliant (1)

### 1. Files cleared by adding `override func tearDown()` (33)

Each file received a minimal `override func tearDown() { super.tearDown() }` (or `tearDownWithError`) inserted at the top of the primary XCTestCase subclass.

1. `PalaceTests/Accounts/AccountSwitchCleanupTests.swift`
2. `PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift`
3. `PalaceTests/AppInfrastructure/AppContainerAuthCoordinatorWiringTests.swift` (`AppContainerAuthCoordinatorRegistrationTests`)
4. `PalaceTests/AppInfrastructure/AppContainerImageLoaderInjectionTests.swift`
5. `PalaceTests/AppInfrastructure/AppContainerTests.swift`
6. `PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift`
7. `PalaceTests/AppInfrastructure/AuthCoordinatorTelemetryTests.swift`
8. `PalaceTests/AppInfrastructure/RemoteFeatureFlagsTests.swift`
9. `PalaceTests/Audiobook/AudiobookLoaderPredicateTests.swift`
10. `PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift`
11. `PalaceTests/Audiobook/Vendors/OpenAccessAdapterTests.swift`
12. `PalaceTests/Audiobooks/AudiobookLoaderFinalizeBuildTests.swift`
13. `PalaceTests/Book/TPPBookDRMProtectedTests.swift` (`TPPBookIsDRMProtectedTests`)
14. `PalaceTests/ButtonStateTests.swift`
15. `PalaceTests/CatalogDomain/CatalogLaneSortingTests.swift`
16. `PalaceTests/Contract/PositionWriterContractTests.swift`
17. `PalaceTests/CoverageGapTests3.swift` (added to `AudioBookmarkGapTests` — primary class; lint is file-level so one tearDown covers the file)
18. `PalaceTests/Logging/DeviceLogCollectorTests.swift`
19. `PalaceTests/Logging/ErrorLogExporterTests.swift`
20. `PalaceTests/Logging/LogTests.swift`
21. `PalaceTests/MyBooks/MyBooksDownloadCenterAccountIdThreadingTests.swift`
22. `PalaceTests/Network/ReachabilityTests.swift`
23. `PalaceTests/Notifications/NotificationSyncThrottleTests.swift` (added to `NotificationSyncThrottleTests` — primary class)
24. `PalaceTests/OPDS2/OPDS2CatalogWiringTests.swift`
25. `PalaceTests/ProblemReportEmailTests.swift` (had `setUp` only; added `tearDown` that nils `emailService` before calling super)
26. `PalaceTests/Reader/ReaderEditingActionsTests.swift`
27. `PalaceTests/Reader2/Typography/FontManagerTests.swift`
28. `PalaceTests/SignInLogic/SignInModalLifecycleTests.swift`
29. `PalaceTests/Support/TestAppContainerFactoryTests.swift`
30. `PalaceTests/Support/TPPUserAccountTestFactoryTests.swift` (had `setUpWithError`; added matching `tearDownWithError`)
31. `PalaceTests/Support/XCTestCase+testUserDefaultsTests.swift`
32. `PalaceTests/TPPUserNotificationsTests.swift`
33. `PalaceTests/VisualRegression/AnonymousBorrowFixtureTests.swift` (added to `AnonymousBorrowBaselineFixtureTests` — primary class)

### 2. Files already compliant (no edits) (3)

These three files already had `override func tearDown() async throws` on their primary class (presumably added by the Module B audiobook DI work). The lint's `hasTearDownOverride` is file-level so these passed already — they were stale baseline entries:

1. `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` — has `override func tearDown() async throws` at line 59 (predates this pass).
2. `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` — `AudiobookSessionStateTransitionTests` has `override func tearDown() async throws` at line 31.
3. `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` — `PlaybackBootstrapperTests` has `override func tearDown() async throws` at line 32.

### 3. Files that never triggered the lint (1)

1. `PalaceTests/Support/XCTestCase+testUserDefaults.swift` — this is an `extension XCTestCase` file, NOT a class declaration. The lint's `declaresXCTestCaseSubclass` regex `\bclass\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*XCTestCase\b` does not match `extension XCTestCase`, and the only `class … XCTestCase` reference in the file (line 33) is inside a `///` doc-comment that the lint strips. **Baseline false-positive from generation time.** No edit required; removed from baseline.

### 4. Files with residue (0)

None. All 37 baseline entries are resolved.

## Baseline shrink

The new baseline retains **1 entry only**, kept as a self-test hold:

```
PalaceTests/AppInfrastructure/AppContainerTests.swift
```

Why one entry: the lint's own `testBaselineFileIsLoaded` self-test asserts (a) `!baselinedFiles.isEmpty` and (b) the set contains `AppContainerTests.swift` OR `CoverageGapTests3.swift`. Emptying the baseline file would break that self-test. The retained entry is COMPLIANT (it has its own tearDown override added in this pass) — membership is purely a self-test hold, not a real exemption. The structural protection (rejecting NEW polluter files without tearDown) is unaffected.

Future shrink path: relax the spot-check inside the lint self-test, then drop the last baseline entry.

## DoD evidence

### Build + per-test PASS

- **Build:** `xcodebuild ... build-for-testing` → `** TEST BUILD SUCCEEDED **` on `/tmp/swarm_cd181acd_E`.
- **Lint test:** `TearDownRequiredLintTests` — 5/5 PASS:
  - `testLintCatchesSyntheticViolator` (0.005s)
  - `testLintAcceptsInheritedTearDown` (0.003s)
  - `testLintAcceptsExplicitTearDown` (0.002s)
  - `testBaselineFileIsLoaded` (0.004s)
  - `testTearDownRequired_runsAgainstPalaceTestsTree` (1.096s)
- **Sample test runs across modified files:**
  - Batch 1 (8 classes): 89 tests, 0 failures
  - Batch 2 (9 classes): 66 tests, 0 failures
  - Batch 3 (10 classes): 54 tests, 0 failures
  - Batch 4 (13 classes): 65 tests, 0 failures
  - **Total: 274 tests run across modified files, 0 failures, 0 unexpected**

No file's existing tests broke after the `tearDown` addition.

### DoD self-checks applicable to this change

This is mechanical test-hygiene work — only the universal checks apply:

| # | Check | Result |
| - | --- | --- |
| 1 | SUT instantiation | N/A — no new `<SUT>Tests.swift` files |
| 2 | Function-result usage | N/A — no new production-code calls |
| 3 | Multi-step test body | N/A — no test methods authored |
| 4 | Scope coverage audit | 37/37 entries drained — full scope landed |
| 5 | Mutation pass | N/A — no production-code changes |
| 6 | Build + verify-pr | Build SUCCEEDED, lint tests PASS, sample tests PASS |
| 7 | Wiring-claim coverage | N/A |
| 8 | Contract reconciliation | N/A — no contract claims in this work |
| 9 | Blast-radius check | `python3 scripts/check-blast-radius.py --quiet` → exit **0** |
| 10 | Adjacency-staleness | `python3 scripts/check-adjacency-staleness.py --quiet` → exit **0** |
| 11 | Superpartner spectrum | N/A — no new functions or enum cases |

### Constraints honored

- **No commits.** Changes left staged/unstaged for orchestrator review.
- **No force unwraps.** Each added override is `super.tearDown()` (or `try super.tearDownWithError()`) — no unwraps.
- **Off-limits territory.** No edits to `Palace/**` production code, no edits to D's UserDefaults/AppContainer territory, no edits to `TearDownRequiredLintTests.swift` itself.
- **Test fluff.** The added `tearDown` overrides are minimal scaffolding (call super), not assertions — they are infrastructure, not test bodies. They do not appear in test counts or coverage.

## Files diffed

37 files touched (36 production test files + 1 baseline file):
- 33 test files: added new `override func tearDown()` / `tearDownWithError()` override.
- 1 test file (`ProblemReportEmailTests.swift`): augmented existing `setUp()` with a matching `tearDown()` that nils the held service.
- 1 test file (`TPPUserAccountTestFactoryTests.swift`): augmented existing `setUpWithError()` with a matching `tearDownWithError()`.
- 1 baseline file (`.forgeos/swarms/swarm_47883816/E-teardown-baseline.txt`): shrunk from 37 entries to 1 hold-pin entry.

## Final lint test verdict

```
Test Suite 'TearDownRequiredLintTests' passed
  Executed 5 tests, with 0 failures (0 unexpected) in 1.109 (1.116) seconds
```

The structural protection remains intact: future test files that touch polluter substrings without declaring `tearDown` (and are not in the baseline) will be rejected by `testTearDownRequired_runsAgainstPalaceTestsTree`. The baseline is now effectively drained — the single remaining entry is a self-test hold, not a real exemption.
