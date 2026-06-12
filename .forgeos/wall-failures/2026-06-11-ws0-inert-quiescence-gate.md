---
date: 2026-06-11
pr: "fleet/w-stabilize (WS-0/M0, pre-PR)"
source: near-miss
reviewer_ids: []
changeset_id: ""
wall: hook
walls: [TDD, verify-pr, hook]
severity: high
wall_status: applied
applied_in: "fleet/w-stabilize"
detector_script: "PalaceTests/MetaTests/RuntimeQuiescenceLintTests.swift + PalaceTests/Support/PalaceTestCase.swift"
detector_status: built
no-detector: ""
name: ws0-inert-quiescence-gate
type: evolving
status: active
created: 2026-06-11
last_refresh: 2026-06-11
freshness_window: 365d
owners: [general]
description: A test-isolation gate passed compile + suite-green three times while being completely INERT — caught only by an empirical synthetic-polluter RED→GREEN proof.
---

# A "green" test-isolation gate that caught nothing — three inertness traps

## What escaped (the near-miss)

While building the WS-0/M0 runtime-quiescence gate (prevents a test leaving
`AccountsManager.deferInitialLoadCatalogsForTesting = false` and starving the
cooperative pool), the gate reached **`** TEST SUCCEEDED **` three separate
times while being completely INERT** — it would never have failed a real
polluter. Each inert form passed "it compiles" AND "the suite is green." Only an
explicit **synthetic-polluter wiring proof** (a test that deliberately leaves
the suite dirty and MUST fail) exposed each one.

If any of the three had shipped, M0 would have reported a trustworthy-green gate
that detected nothing — exactly the fake-gate failure the green-board contract
exists to prevent, on the gate that blocks every merge.

### Trap 1 — `XCTestCase.record()` from `testCaseDidFinish` is silently dropped
The first design failed the run from an `XCTestObservation` observer via
`testCase.record(XCTIssue(...))`. Recording an issue against an already-finished
test from `testCaseDidFinish` does **not** fail it. Synthetic polluter passed.

### Trap 2 — randomized test order defeats a trailing "final gate"
The second design accumulated breaches and asserted in a `ZZZZ…`-named class
intended to sort last. `Palace.xcscheme` runs `testExecutionOrdering = "random"`
(lines 88/99), so the "final" gate ran FIRST and read an empty accumulator. No
statically-named class is guaranteed last under randomized order. (This same
randomization is the mechanism behind the original flake's "victim varies per
run.")

### Trap 3 — `#if DEBUG` compiled the gate to a constant `true`
The auditor guarded its flag read with `#if DEBUG`. The **`PalaceTests` target
does not define `DEBUG`** (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = LCP
FEATURE_OVERDRIVE`), so the guard compiled to the `#else` branch (`return true`)
and the gate read "quiescent" forever. The test bodies' `#if DEBUG` flag-flips
were likewise compiled out.

## Which wall(s) should have caught it

- **TDD / verify-pr:** a gate is production code for the test suite; it needs a
  RED test proving it fails a known-bad input before it is trusted. "Self-test
  the detector on a synthetic violation" (the pattern
  `AppContainerIsolationLintTests.testLintCatchesSyntheticViolation` already
  uses) is the wall — it was initially only applied to the *pure* detector, not
  the *wiring*.
- **hook:** had this been wired as a hook/CI gate without a clean+dirty fixture,
  the inertness would have been invisible (green-board contract #4: "a detector
  invoked with an interface it rejects must not block — always assert the clean
  path passes too," and its inverse: assert the DIRTY path FAILS).

## Permanent fix (applied in this branch)

1. **The gate is now a per-test `XCTFail` in `PalaceTestCase.tearDownWithError`**
   (deterministic, order-independent, attributed) — not an observer record and
   not a trailing test.
2. **No `#if DEBUG` in test-target gate code** — reference test-only symbols
   directly via `@testable import` (they exist because the main module is
   `DEBUG`-built); gate any env conditioning on `XCTestConfigurationFilePath`,
   never `#if DEBUG`. (Also a blast-radius rule.)
3. **`RuntimeQuiescenceGateTests` + `RuntimeQuiescenceLintTests` self-test BOTH
   directions** — a synthetic polluter MUST be flagged AND a clean input MUST
   pass. The lint adds a GOOD-path and CLEAN-path assertion alongside the BAD.
4. **Process lesson (the durable one):** a test-isolation / quiescence / leak
   gate is not "done" on compile + suite-green. It is done when an empirical
   **RED→GREEN proof** shows it fails a deliberately-planted polluter and passes
   clean. Captured in `docs/architecture/runtime-quiescence-gate.md` §"Three
   inertness traps."

## Derived improvement (proposed for the catalog)

When reviewing ANY new gate/detector/hook, ask: "show me the run where a planted
violation made it RED." If the only evidence is "it compiles" or "the suite is
green," the gate is unverified — three inert forms each satisfied both.
