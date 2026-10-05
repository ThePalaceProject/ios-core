# Coverage Floor Enforcement

Per-module and per-package coverage floors, reported on every PR. The floor
step does not block a merge today (see "Warn vs blocking mode").

## How it works

1. The build job runs `scripts/ci-xctestrun-package-coverage.py` on the
   `.xctestrun`. Xcode records each local package framework in its coverage
   metadata as static (and leaves some out), so without this step xccov reports
   those packages with no files.
2. The test shards run the app suite with coverage. The shard that runs the
   host-buildable packages runs `swift test --enable-code-coverage` and uploads
   one llvm-cov export per package (`package-coverage` artifact).
3. `Parse Code Coverage` runs `scripts/coverage-report.py`, which writes
   `coverage-data.json` with three separate measurements, each with raw
   covered/executable line counts:
   - `app`: source under `Palace/` outside `Palace/Packages`. The top-level
     fields (`testable_coverage`, ...) are this measurement, so the app metric
     keeps the denominator it had before package source was collected.
   - `packages_app_suite`: `Palace/Packages/<P>/Sources`, from the app suite.
   - `packages_host`: the same sources, from `swift test` on macOS. Different
     instrumentation and platform conditionals; never added to the app suite.

   Files matched by `coverage-exclude.json` are reported as excluded in each
   measurement. Every other file (PalaceTests and other test sources, the
   toolkit submodule, anything outside the checkout or generated) is counted
   under `unattributed` and in no measurement. A path seen in several
   targets is counted once (the entry with the most covered lines) and listed
   under `duplicates`.
4. `Enforce Coverage Floors` runs
   `scripts/enforce_coverage_floors.py coverage-data.json --floors scripts/coverage-floors.json`
   and prints `module | floor | actual | status`. Package rows are named
   `pkg:<Package>` (app suite) and `host:<Package>` (`swift test`).
   `package_modules` holds module floors for files that moved into a package
   (TPPBookRegistry).

## Incomplete data

`coverage-report.py` sets `status: incomplete`, lists the reasons, and exits 3
when the result bundle is missing or unreadable, the app suite recorded no
executed line, a planned test class did not run, an expected package has no
data, or an expected `swift test` export is missing. The JSON is still written.
`enforce_coverage_floors.py` exits 3 on any report whose status is not
`complete` and does not compare floors.

Exit codes of `enforce_coverage_floors.py`: `0` pass, `1` floor violated or a
floored module/package missing, `2` input error, `3` incomplete data.

A package with no data needs a named exemption in `coverage-exclude.json`
(`unmeasured_packages`, with the reason and follow-up) to keep the report
complete. A local Xcode run does not rewrite the coverage metadata, so
`coverage-report.py` only expects packages when given `--expect-package` or
`--expect-local-packages` (CI passes the latter). The report records what it
expected, and the floor step compares `packages`, `package_modules` and
`host_packages` only for a run that expected that measurement; a local run
(including `scripts/verify-pr.sh`) compares the app floors and notes the rest.

## Updating floors

Edit `scripts/coverage-floors.json`. Floors are fractions (`0.46` = 46%).

To capture a complete run's actuals as the new baseline (rounded down, so the
run that wrote them passes):

```bash
python3 scripts/enforce_coverage_floors.py coverage-data.json \
  --floors scripts/coverage-floors.json --write-baseline
```

## Warn vs blocking mode

The step runs with `continue-on-error: true` in
`.github/workflows/unit-testing.yml`, so a violation or incomplete data shows in
the step and the PR comment but does not fail the run. Making it blocking means
removing `continue-on-error: true` from `Enforce Coverage Floors` and adding the
report job's result to the required check; with the floors as recorded, several
modules are below their floor on current develop, so that change has to come
with either the tests that raise them or an owner decision on the floors.

## Local use

```bash
python3 scripts/enforce_coverage_floors.py coverage-data.json
python3 scripts/enforce_coverage_floors.py coverage-data.json --baseline-only
```

`--baseline-only` treats the current actual as the floor (no-regression check)
without modifying the floors file.
