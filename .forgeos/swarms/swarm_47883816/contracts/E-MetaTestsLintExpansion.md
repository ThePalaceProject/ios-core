# Contract E — MetaTestsLintExpansion

## Scope

Expand `MockIsolationLintTests` rules from `PalaceTests/Mocks/` scope to all of `PalaceTests/**` with a documented exception list. Add new lint test `TearDownRequiredLintTests` that requires any test class referencing polluter patterns to declare an `override func tearDown`.

### Files (MODIFY)
- `PalaceTests/MetaTests/MockIsolationLintTests.swift` — change `mocksRoot` to walk `PalaceTests/**` minus exception list

### Files (NEW)
- `PalaceTests/MetaTests/TearDownRequiredLintTests.swift`

## TearDown rule

Any test class FILE that contains any of these polluter patterns:
- `.shared` (singleton access)
- `AccountsManager(` (the constructor call)
- `AppContainer.production()`
- `NotificationCenter.default.addObserver`
- `UserDefaults.standard.set`

MUST have one of:
- `override func tearDown()`
- `override func tearDownWithError()`
- `override func tearDown() async throws`
- Inherits from a class whose name ends with `TestCase` (e.g. `PalaceWiringTestCase`) — assumed to provide tearDown via inheritance

Implementer documents inherited bases in the lint test source as a whitelist.

## Off-limits

- All A, B, C, D-owned NEW lint files (those are owned by their modules — E only modifies the existing MockIsolationLintTests + adds TearDownRequiredLintTests)
- All production code

## Dependencies

**E depends on A, B, C, D landing first.** E's lint exception list references the whitelist files A/B/C/D establish. The orchestrator dispatches E only after A/B/C/D return.

## Verification criteria

| # | Criterion | Command |
|---|---|---|
| 1 | `MockIsolationLintTests` now walks `PalaceTests/**` | `grep -n "mocksRoot\|PalaceTests/" PalaceTests/MetaTests/MockIsolationLintTests.swift` shows the broadened path |
| 2 | Synthetic violator detection for MockIsolationLint | Add temp file path or string fixture; lint test runs against synthetic input and fails |
| 3 | TearDown lint catches synthetic violator | `testLintCatchesSyntheticViolation` |
| 4 | Build clean | PASS |
| 5 | verify-pr.sh --quick clean | PASS |
| 6 | E's lints respect A/B/C/D whitelists | Exception lists in E reference the committed whitelist files from A/B/C/D verbatim (or by stable identifier) |
