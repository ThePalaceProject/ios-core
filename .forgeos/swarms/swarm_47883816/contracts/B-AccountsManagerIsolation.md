# Contract B — AccountsManagerIsolation

## Scope

Migrate the raw `AccountsManager()` call sites outside the `PalaceWiringTestCase` factory to use the existing `PalaceWiringTestCase.makeFreshAccountsManager()` seam. Add a lint test that bans bare `AccountsManager(` outside the whitelist.

### Files (NEW)
- `PalaceTests/MetaTests/AccountsManagerIsolationLintTests.swift`

### Files (MODIFY — 9 migration files)
- `PalaceTests/Integration/AccountSwitchLifecycleTests.swift` (line 61)
- `PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift` (line 89)
- `PalaceTests/Integration/ColdStartResumeIntegrationTests.swift` (line 45)
- `PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift` (line 75)
- `PalaceTests/Accounts/AccountsManagerCancellationTests.swift` (lines 64, 132, 201, 240, 295)
- `PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift` (lines 49, 247, 273)
- `PalaceTests/BookRegistry/TPPBookRegistryDependencyTests.swift` (lines 45, 63)
- `PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift` (line 45)
- `PalaceTests/BookRegistry/TPPBookRegistryLargeCorpusTests.swift` (line 43)
- `PalaceTests/BookRegistry/TPPBookRegistryMigrationTests.swift` (line 39)

Net migration target: ~17 sites in 10 files (architect verified — the original "24" included PalaceWiringTestCase.swift internal refs + comment-only refs in AppContainerResetTests).

## Migration approach (implementer's choice per file)

Two options per file:

**Option 1 — Subclass PalaceWiringTestCase**: change `class XTests: XCTestCase` to `class XTests: PalaceWiringTestCase`; replace `AccountsManager()` with `makeFreshAccountsManager()`. Requires the subclass to call `super.setUpWithError()` / `super.tearDownWithError()`. Cleanest for files with simple setUp.

**Option 2 — Static seam adapter**: add `internal static func makeFreshAccountsManager(_ configure: (AccountsManager) -> Void = { _ in }) -> AccountsManager` to PalaceWiringTestCase so callers can use `PalaceWiringTestCase.makeFreshAccountsManager()` from any test class. The instance is auto-cancellable via a process-wide tracker that drains on `XCTestObservation.testCaseDidFinish` (registered with `SingletonResetRegistry`).

**Architect recommendation**:
- **Option 2** for the 4 `Integration/*` files (they have complex setUp inheriting from other base classes)
- **Option 1** for the 5 `BookRegistry/*` and `AccountsManagerCancellationTests.swift` files (cleaner; no base-class conflict)

Implementer documents the choice per file in the migration transcript.

## Whitelist (lint exceptions)

| File | Reason |
|---|---|
| `PalaceTests/Support/PalaceWiringTestCase.swift` | Defines the seam (the ONE legal `AccountsManager()` call) |
| `PalaceTests/Support/PalaceWiringTestCaseTests.swift` | Tests the seam directly |
| `PalaceTests/AppInfrastructure/AppContainerResetTests.swift` | Comment-only refs to historical `AccountsManager()` pattern |
| `PalaceTests/Mocks/**` (existing mocks) | Mock implementations |

## Off-limits

- All A, C, D, E files (per assignment matrix)
- `Palace/**` (production code)
- `PalaceTests/Support/PalaceWiringTestCase.swift` (only existing seam is OK; do NOT change `makeFreshAccountsManager()` signature without orchestrator approval)

## Verification criteria

| # | Criterion | Command |
|---|---|---|
| 1 | Migration grep returns 0 hits | `grep -rn "AccountsManager(" PalaceTests --include="*.swift" \| grep -v "Mock\|Fake\|makeFreshAccountsManager\|PalaceWiringTestCase\.swift\|PalaceWiringTestCaseTests\.swift\|AppContainerResetTests\.swift"` → 0 lines |
| 2 | Lint catches synthetic violator | `testLintCatchesSyntheticViolation` passes |
| 3 | All 17 migrated tests still pass | Per-class `xcodebuild -only-testing` runs PASS, xcresult paths pasted per DoD #7 |
| 4 | No new public API in PalaceWiringTestCase | `grep -c "public " PalaceTests/Support/PalaceWiringTestCase.swift` — same count as before |
| 5 | Build clean | PASS, tail pasted |
| 6 | verify-pr.sh --quick clean | PASS |
| 7 | Blast-radius | `python3 scripts/check-blast-radius.py --quiet` exit 0 |
| 8 | Contract reconciliation | exit 0 |
