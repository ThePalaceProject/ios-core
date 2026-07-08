# Investigator F: Suite-Ordering Amplifier (Random Execution)

## Mode
INVESTIGATION ONLY. No production-code, test-file, or scheme edits.

## Hypothesis
The Palace and Palace-noDRM schemes both set
`testExecutionOrdering = "random"`. This is the AMPLIFIER for categories A-D:
- A clean test suite's pollution is invisible at any single ordering.
- Random ordering exposes the pollution non-deterministically.
- A "stable for a week then flaky again" pattern (what the user reports) is
  exactly the seed changing.
- M1's pre-push gate that ran 23 test classes "PASSED clean" — because 23 classes
  is below the singleton-residue threshold AND below the URL-stub-collision
  surface. The full suite (485 XCTestCase classes) is where the amplifier bites.

## Evidence the category exists
- `Palace.xcodeproj/xcshareddata/xcschemes/Palace.xcscheme`:
  `testExecutionOrdering = "random"`
- `Palace.xcodeproj/xcshareddata/xcschemes/Palace-noDRM.xcscheme`:
  `testExecutionOrdering = "random"`
- 485 PalaceTests XCTestCase classes; 271 with custom lifecycle (setUp/tearDown).
- M1 23-class pre-push gate green; develop CI red on the same code (per user brief).
- `regression_develop_2026_05_11_evening.md`: 1,049/1,049 PASS in isolation,
  flake under full suite — random seed differs.

## What to look for

### 1 — Confirm current scheme settings
- `grep -n "testExecutionOrdering" Palace.xcodeproj/xcshareddata/xcschemes/*.xcscheme`
- Confirm both schemes are random; note any per-bundle override.

### 2 — Identify test-class-pairs that share singletons
This is the "blast-radius" of randomness. Cross-reference Investigator A's
HIGH-severity list: each pair of HIGH-severity classes is a potential ordering
flake.

### 3 — Identify suite-level vs class-level resets
- Does `PalaceTestSetup.swift` (`PalaceTests/PalaceTestSetup.swift` — confirmed
  to exist from build log) install global resets in `+ load` or
  `XCTestObservation`?
- If yes: are those resets idempotent and side-effect-free?

### 4 — Parallel test bundle config
- Check `Test Plans` (`.xctestplan` files) for `parallelizable` / `parallelTestingDisabled`.
- Note any `executionTimeAllowance` settings — long allowances mask flakes.

### 5 — Compare what M1 gate runs vs. full suite
- M1's targeted 23-class gate: identify the 23 classes (likely in
  `scripts/verify-pr.sh` or a config file). What singleton/stub surfaces do they
  use? Why are they immune?

## Where to look
- `Palace.xcodeproj/xcshareddata/xcschemes/Palace.xcscheme`
- `Palace.xcodeproj/xcshareddata/xcschemes/Palace-noDRM.xcscheme`
- `Palace.xcodeproj/**/*.xctestplan`
- `PalaceTests/PalaceTestSetup.swift`
- `scripts/verify-pr.sh`
- M1's "targeted 23 classes" gate config (likely `scripts/run-targeted-tests.sh`
  or similar)

## Evidence to collect
```
finding | scope | impact | proposed_action_shape
```
- Random ordering setting | both schemes | amplifies A-D | option (a) deterministic seed in CI / option (b) keep random + add round-tripping reset hooks
- Suite-level cleanup gap | PalaceTestSetup.swift | global pollution | option: XCTestObservation seam that resets singletons between classes
- M1 23-class surface | green gate vs. red full suite | bisection target | option: progressively widen the green set until first flake to bisect the residue source

## Proposed fix SHAPE
1. **Two parallel CI signals, not one:**
   - **Seeded-random** suite run with seed pinned per branch (deterministic flake
     reproduction).
   - **Rotating-seed** suite run that explicitly TRIES new orderings
     (flake-discovery).
   Both report independently to the merge gate.
2. **XCTestObservation seam** in `PalaceTestSetup.swift` that calls a registered
   list of `_resetAllForTesting` between EACH XCTestCase class (not just between
   tests within a class). Single point of cross-class hygiene.
3. **Re-run-failed-tests-in-isolation** step in CI: any test that fails reruns
   alone; if it passes, the failure is marked "suite ordering flake" and reported
   to a dashboard rather than blocking merge.
4. **Triage script**: `scripts/test-bisect-ordering.sh` that takes a failing test
   name and binary-searches the preceding test order to find the polluter.

## NOT in scope
- Do NOT propose disabling random ordering. That hides the bug; it doesn't fix it.
- Do NOT propose parallel test bundle changes — out of swarm scope.
- No scheme edits.

## Output contract
Same shape as Investigator A. Plus a NARRATIVE section linking F findings back
to A/B/C/D findings (since F is the amplifier, the integrator needs the
cross-reference to write the unified plan).
```

---
