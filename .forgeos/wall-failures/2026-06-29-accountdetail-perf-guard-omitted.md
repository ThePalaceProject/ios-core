---
date: 2026-06-29
source: near-miss
walls: [implementer, reviewer]
severity: medium
wall_status: open
---

# accountdetail-perf-guard-omitted

## Finding

Independent SoD architect review (rev_f1d31c74) BLOCKED #1 (a91aaa8db, the O(1)
`AccountsManager.account()` index that fixes the AccountDetailViewModel hang):
the design doc `docs/architecture/hermeticity-accountdetail-hang-fix-design.md`
(Fix #1 → "Structural guard") committed to a **complexity-contract test pinning
that `account()` does not scale with N** — but the shipped tests
(`AccountsManagerAccountIndexTests`, 5 cases) were all correctness/coherence
(incl. the desync guard). The desync test guards index COHERENCE, not the O(1)
COMPLEXITY contract. Since O(1) *is* the hang fix, its core property shipped with
no recurrence guard: a revert to the old `accountSets.values.first { contains }`
O(n) scan would pass every test.

## What actually happened

The correctness tests (multi-bucket resolve, reseed desync, boundary, pure
builder) all genuinely pass and look thorough, which masked the absence of the
one guard that matters for the fix's PURPOSE. "Lots of green tests" read as
"well-tested" while the complexity invariant — the whole reason for the change —
was unguarded. The design had already named the guard; the implementer simply
did not reconcile the shipped test set against the design's committed guards
before declaring READY.

## Walls that should have caught it

- **Implementer (TDD/DoD):** the Definition-of-Done self-checks verify tests
  exist + kill mutants, but mutation was near-zero-surface here (dict + for-in),
  so the kill-rate signal was empty AND there was no check that the design's
  *named* guards were actually implemented.
- **Reviewer:** caught it (SoD architect BLOCK) — so the human/role wall held,
  but only after READY was declared. The gap is structural: nothing reconciled
  "design committed guard X" against "diff contains a test for X" earlier.

## Proposed permanent fix

A reconciliation check: when an intent/design doc commits to a named guard test
(phrases like "guard", "contract test", "recurrence guard", "must FAIL on
revert", "pin … does not scale"), the diff must contain a test whose name/body
references that property before promote — analogous to
`check-contract-reconciliation.py` for "removes X / adds Y" claims, but for
"design-committed guard ⇒ test present". Grep-able seed: scan the changeset's
design/intent docs for `recurrence guard|complexity contract|must FAIL|does not
scale|perf[- ]contract` and require a matching test selector in the diff.
Until that detector exists, add a DoD self-check line: "for every guard the
design NAMES, paste the test that implements it." Catches this exact class
(design-committed-guard-shipped-without-it).

## Application log

- 2026-06-29: filed. Perf-contract guard added in
  `AccountsManagerAccountIndexTests.testAccount_lookupIsConstantTime_notLinearInAccountCount`
  (comparative small-vs-large bucket timing; O(n) revert ⇒ ~40× ⇒ fails the 8×
  ceiling). Clears rev_f1d31c74 requirement #1. Detector (#2) proposed above,
  not yet implemented — tracked here.
