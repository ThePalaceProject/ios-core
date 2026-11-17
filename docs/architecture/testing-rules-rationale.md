# Why the testing and CI rules in CLAUDE.md exist

`CLAUDE.md` states the rules. This page keeps the incidents behind the ones
whose reason is not obvious from the rule itself.

## Full suite, not `-only-testing`, before calling a change verified

A `-only-testing:PalaceTests` run was once reported as "full local suite, 0
failures". It covered one test bundle out of two (about a third of the
executions CI runs), and it had hung and ended `** TEST FAILED **`. CI runs the
whole `Palace` scheme across `PalaceTests` and `TenPrintCoverTests` with
`-test-iterations 3 -retry-tests-on-failure`, so a class-scoped run is a spot
check and nothing more. Per-suite `Executed N` lines double- and triple-count
under retries, which is why the rule says to read the top-level rollup.

## Green-board contract

PR #1045 shipped a `verify-pr.sh` that failed `bash -n` and a pre-commit hook
that would have blocked every commit. The board was already red from test
pollution, so the new failure did not stand out. Hence: retries absorb flakes,
pollution gets fixed at its source (`scripts/find-test-polluter.sh`), the
tooling has its own CI job (`tooling-checks.yml`), and `--admin` is reserved
for a named, tracked flake.

**Scan green runs.** With `-test-iterations 3`, a run that passes its first
iteration stops at one sample per test, and a run that stumbles goes to three,
from the same command. A green run can contain tests that failed an iteration,
including on the borrow and auth paths. `scripts/ci-test-history.py --scan`
prints those and the sampling depth; one sample per test is weak evidence.

**History before theory.** A toolkit-bump PR (#1380) went red and the first
explanation offered was runner oversubscription. Comparing the same test
against the previous green run (#1377) showed it passing in milliseconds there
and failing after 69 seconds on the branch, which settled it: the branch
introduced it. `ci-test-history.py <TestClass>` produces that table in one
command. A test that never appears in a run may have been renamed or never
registered, which looks the same as passing.

**Load-sensitive tests.** A test that flips with unrelated load measures the
machine. `AccountRegistryStorePoolStarvationTests` shows the fix: assert that
operations complete, and keep the load-sensitive variant behind an env flag.

## Mutation testing rules

- **Mechanical mutants only.** A hand-written mutation list scored "7/7 killed"
  on a state machine while a mutant derived by `palace_mutate.py` — deleting a
  branch of the changed line — left the suite green. A hand-picked list
  restates the tests you already believe in.
- **A build failure is not a kill.** Scripts that key off a non-zero exit count
  compile failures as kills, including `no such module 'PalaceUIKit'` from a
  cold DerivedData. `palace_mutate.py` reports `errored` separately.
- **A kill rate is not coverage.** In the same change, every mutant was killed
  while one (state, event) cell had no test at all; each defect review found
  afterwards was an unenumerated cell (`claim` from `.failed(n)`, `failure`
  from `.loading(superseded: true)`, a position exactly on a chapter boundary).
- **Call-site census for shared helpers.** A chapter-boundary fix passed 225
  tests and would have paused audiobook playback at every chapter, because two
  players compared the helper's results across a boundary to decide whether to
  keep playing. Reading the callers found it; no test did.

## Adding a detector

Detectors that block commits cost every contributor time on every commit. One
past effort built about 600 lines of commit-blocking tooling for a bug class
with no instances in the tree. A new `check-*` script now needs a real
instance, or a near-miss that reached review or production, and should replace
an existing check where one overlaps.
