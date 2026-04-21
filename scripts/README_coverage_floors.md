# Coverage Floor Enforcement

A merge gate that fails CI if per-module coverage drops below configured floors.

## How it works

1. The existing CI step `Parse Code Coverage` runs `scripts/coverage-report.py`,
   which writes `coverage-data.json` (overall + per-target + per-file coverage).
2. The new step `Enforce Coverage Floors` runs
   `scripts/enforce_coverage_floors.py coverage-data.json --floors scripts/coverage-floors.json`.
3. The script compares actuals to floors and prints a table:
   `module | floor | actual | status`.
4. Exit codes: `0` pass, `1` floor violated, `2` input error.

## Updating floors

Edit `scripts/coverage-floors.json`. Floors are fractions (`0.46` = 46%).

To capture today's actuals as the new baseline:

```bash
python3 scripts/enforce_coverage_floors.py coverage-data.json \
  --floors scripts/coverage-floors.json --write-baseline
```

## Warn vs blocking mode

Day 1 the gate runs with `continue-on-error: true` in
`.github/workflows/unit-testing.yml` — it reports but does not block merges.
Once the floors are trusted, flip the gate to blocking by removing
`continue-on-error: true` from the `Enforce Coverage Floors` step.

## Ratcheting strategy

1. Phase 1 (now): floors set to current actuals; gate is warn-only.
2. Phase 2 (post mutation baseline): flip to blocking; raise floors by 2-5
   points per module per sprint until they meet the master test plan targets.
3. Always raise floors via `--write-baseline` after a green run, then commit
   the resulting `coverage-floors.json`.

## Local use

```bash
python3 scripts/enforce_coverage_floors.py coverage-data.json
python3 scripts/enforce_coverage_floors.py coverage-data.json --baseline-only
```

`--baseline-only` treats the current actual as the floor (no-regression check)
without modifying the floors file.
