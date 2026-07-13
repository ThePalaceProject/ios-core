# Test Quality Posture (not a coverage roadmap)

**There is no line-coverage target and no coverage gate.** An earlier version of
this file laid out a 6-week plan to hit 80% line coverage. That target has been
retired: it contradicted the repo's actual quality posture and encouraged
coverage-only tests, which are explicitly banned (see `CLAUDE.md` →
"TDD & Test Quality"). Coverage is a byproduct of good tests, not a goal.

> Honest 35% coverage with tests that catch bugs is better than 50% coverage
> with tautologies that catch nothing.

## The real quality bar

Test value is measured by whether a test would fail when the production code it
covers regresses — not by how many lines it executes. The canonical mechanisms,
all defined in `CLAUDE.md`:

- **TDD** — production changes get a failing test first.
- **Mutation kill-rate** — `scripts/palace_mutate.py --file <f> --tests <class>
  --diff-only`. Diff-scoped kill rate must be ≥ 50% (ideally 100% on touched
  lines) for critical paths (`Palace/Audiobooks/`, `Palace/SignInLogic/`,
  `Palace/MyBooks/Download*`, auth/borrow/return/DRM/credentials). Local-only —
  run in `/regression` and pre-release, not CI (see `CLAUDE.md` →
  "Mutation testing").
- **Contract-snapshot tests** — for state machines that emit ordered dependency
  calls (`Borrow`, `BookReturn`, `DownloadStart`, `BorrowReducer`). Framework in
  `PalaceTests/Contract/`.
- **Definition of Done (11 checks)** — SUT-instantiation, function-result usage,
  multi-step body, scope-coverage, mutation, build + `verify-pr.sh`,
  wiring-coverage, contract reconciliation, blast-radius, adjacency, and
  test-pairing. Paste evidence before declaring work done.
- **State-machine wiring tests** must drive full round-trips through the
  production seam, not direct `_setState` shortcuts.

Banned patterns (set-then-assert, enum-raw-value asserts, non-nil constructor
asserts, bool toggles, tautologies) and the mutation-survival question are the
gate — see `CLAUDE.md` for the full list.

## Running the suite

Local validation runs the **same full scheme CI runs** — never a
`-only-testing:` subset (that is a spot-check only). Build with the **project**,
not the workspace (the workspace hits Firebase SPM issues), against
**iPhone 16 Pro** (the CI simulator):

```bash
# Full-scheme single pass:
scripts/verify-pr.sh --quick

# CI parity (3 iterations, retry-on-failure):
scripts/xcode-test-optimized.sh

# Build only:
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

A run is green only if it ends `** TEST SUCCEEDED **` with no
`exceeded execution time allowance` / `Restarting after … test timeout` lines.

## If you want to raise coverage of a specific area

Pick an uncovered branch that could actually regress, write a behavior test that
kills a mutant on it, and verify with `palace_mutate.py`. Do not write tests
whose only purpose is to execute a line. If a line has no testable behavior
(fire-and-forget analytics, empty delegate method), leave it uncovered.
</content>
</invoke>
