# Investigator A: Singleton / Global-State Residue

## Mode
INVESTIGATION ONLY. No production-code or test-file edits.

## Hypothesis
A subset of tests instantiates real singletons (`TPPUserAccount.shared`,
`AccountsManager.shared`, `AccountStateStore.shared`, `AppContainer.production()`,
`UserDefaults.standard`, `NotificationCenter.default`) without resetting them in
`tearDown`. Under random execution order, the residue from test N becomes the
hidden setup of test N+1. Develop CI proves this is live: a single process logged
`numAccounts=100` early and `numAccounts=1150` minutes later — accounts bulk-loaded
by one test polluted the AccountsManager seen by later tests.

## Evidence the category exists (already known, do NOT re-derive)
- CI run 26593379677 (PR #1020):
  - `numAccounts=100, currentAccountId (from UserDefaults)=null` at 18:27:43 (OAuth test)
  - `numAccounts=1150, currentAccountId (from UserDefaults)=urn:uuid:1a110ef6-...` at 18:29:27 (auth-doc test, same process)
- `feedback_wiring_suite_test_isolation.md`: `AccountsManager()` init spawns
  `DispatchQueue.global(.background).async { loadCatalogs }` that outlives the test.
  `AccountsManager.swift:157` (`skipBackgroundLoadCatalogs` opt-out) already
  exists — coverage gap, not capability gap.
- `regression_develop_2026_05_11_evening.md`: 1,049/1,049 PASS in isolation,
  flakes under full suite (the textbook residue shape).

## What to look for

### Grep set 1 — direct singleton mutation in tests
```
PalaceTests/**/*.swift
```
Find every test file that calls:
- `TPPUserAccount.sharedAccount(libraryUUID:)` (or `.shared`)
- `AccountsManager.shared` (or `AccountsManager()`-without-the-opt-out)
- `AccountStateStore.shared`
- `AppContainer.production()` (the production composition root)
- `UserDefaults.standard.set` / `.removeObject`
- `NotificationCenter.default.post(name:`
- `TPPBookRegistry.shared` (single source of truth per CLAUDE.md)

For each hit, classify whether the same file's `tearDown`/`tearDownWithError`:
- (a) resets the singleton via `_resetAllForTesting`-shape API, OR
- (b) restores prior state, OR
- (c) **leaves it polluted** (the bug).

### Grep set 2 — AccountsManager() without the opt-out
```
grep -n "AccountsManager(" PalaceTests/**/*.swift
```
Cross-reference against the existence of the `skipBackgroundLoadCatalogs` opt-out
(see `Palace/Accounts/Library/AccountsManager.swift:157-214`). Every `AccountsManager()`
construction in a test that does NOT pass the opt-out is a flake contestant.

### Grep set 3 — UserDefaults pollution
```
grep -rn "UserDefaults.standard" PalaceTests/ | grep -v "// "
```
21 files already known to touch standard UserDefaults. List every key written and
whether it's cleared in tearDown.

### Grep set 4 — NotificationCenter observer leak
```
grep -rn "NotificationCenter.default.addObserver" PalaceTests/
grep -rn "NotificationCenter.default.post" PalaceTests/
```
Identify observers added without paired `removeObserver` in tearDown.

## Where to look
- `PalaceTests/Accounts/` — known hotspot (wiring tests)
- `PalaceTests/ViewModels/` — AccountDetailViewModelTests (long file, real singleton calls)
- `PalaceTests/MyBooks/` — MyBooksViewModelTests, BookCellModel* (book registry)
- `PalaceTests/SignInLogic/` — TPPCrossLibrarySignOutTests, OAuth tests
- `PalaceTests/Integration/` — AccountSwitchLifecycleTests (real flow tests)
- `PalaceTests/Chaos/ChaosFaultInjectionTests.swift` (chaos has weakest isolation)
- `PalaceTests/CoverageGapTests3.swift` (omnibus / catch-all coverage)

## Evidence to collect
For each finding, produce a row:
```
file:line | singleton | reset_in_tearDown? (Y/N/PARTIAL) | severity (HIGH/MED/LOW) | proposed_fix_shape
```
- HIGH = state mutation with NO reset
- MED = reset exists but is incomplete (e.g. only clears one field of a multi-field
  singleton, or only fires in `tearDown` not `tearDownWithError`)
- LOW = singleton read-only (no mutation)

Severity ranking criteria:
- Mutation + no reset + writes through to disk/keychain/UserDefaults = HIGH
- Mutation + reset but reset is fragile (race-y) = MED
- Read-only access to .shared = LOW (not a flake driver but a DI debt signal)

## Proposed fix SHAPE (NOT code — investigator MUST NOT propose specific code)
1. A `PalaceSingletonTestCase` base class whose `tearDownWithError` calls a registered
   set of `_resetAllForTesting` hooks across known singletons. Each new singleton
   registers itself once; tests inherit the cleanup for free.
2. A runnable script `scripts/check-singleton-leaks.py` that fails any new test file
   that calls `.shared` / `.production()` outside the base class.
3. A `verify-pr.sh` gate that runs PalaceTests with `testExecutionOrdering = "random"`
   AND with seeded order, three times. Difference in pass set = flake.

## NOT in scope (off-limits)
- No production-code changes to `AccountsManager`, `TPPUserAccount`, `AppContainer`,
  or any singleton.
- No edits to test files (the goal is to ENUMERATE; the integrator decides the fix).
- Do not propose DI refactors. Memory pin already notes
  "AccountDetailViewModel DI migration is the long-term fix" — out of scope here.

## Output contract
Produce a markdown report:
```
# Investigator A Findings

## Summary
- Total test files scanned: <N>
- HIGH-severity singleton-residue findings: <N>
- MED-severity: <N>
- LOW-severity: <N>

## HIGH findings
<table rows>

## MED findings
<table rows>

## Proposed fix shape (no code)
<paragraph>
```
```

---
