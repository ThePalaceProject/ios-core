# Coverage Floor Enforcement

Per-module and per-package coverage floors, checked on every PR that can affect
the unit tests. An app floor (`overall` or a `modules` entry) more than 1.5
points below its recorded value, or incomplete coverage data, fails the required
`build-and-test` check. Package floors are reported but advisory (see "Blocking
and advisory floors").

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

Edit `scripts/coverage-floors.json`. Floors are fractions (`0.46` = 46%). A
new or re-baselined floor is the measured value rounded down to 4 places; the
run-to-run allowance is `APP_FLOOR_TOLERANCE`, not slack in the value. The
floors set on 2026-09-02 were recorded at least 2 points below their
measurement and keep that margin until they are next re-baselined.

When code moves between files, re-measure every row it touches from one
complete CI run. #1603 moved the network-loss handler out of
`MyBooksDownloadCenter`, which changed that row's line counts; #1601
re-baselined it to 0.6405 and added `DownloadNetworkLossMonitor` at its
measured 1.0.

To capture a complete run's actuals as the new baseline (rounded down, so the
run that wrote them passes):

```bash
python3 scripts/enforce_coverage_floors.py coverage-data.json \
  --floors scripts/coverage-floors.json --write-baseline
```

## Blocking and advisory floors

| Scope | Blocks the PR | Rule |
|---|---|---|
| `overall`, `modules` | yes | fails only when actual < floor - 1.5 points; a row between the floor and that margin reads `WITHIN` |
| `package_modules`, `packages`, `host_packages` | no | a row below its floor reads `FAIL advisory` and does not change the exit code |
| a floor with no data in any scope | yes | `MISSING` |
| incomplete coverage data | yes | exit 3; floors are not compared |

The margin is `APP_FLOOR_TOLERANCE` in `scripts/enforce_coverage_floors.py`; the
floor values themselves are unchanged. Package floors are advisory because
their measurements vary between CI runs of identical code: on #1601, three runs
of the same source (two of one commit; the third changed only a floor value)
measured TPPBookRegistry at 78.5%, 78.5% and 79.7% and
pkg:PalaceBookRegistry at 91.5%, 91.5% and 91.7%, against floors of 79.2% and
91.6% recorded with no slack (`_comment_packages` in `coverage-floors.json`).

`Enforce Coverage Floors` in `.github/workflows/unit-testing.yml` has no
`continue-on-error`, so a blocking violation (exit 1) or incomplete data (exit 3)
fails the `report` job. The required `build-and-test` check needs `report` and
fails unless the floor step's outcome and the report job's result are both
`success`. A PR whose changed paths cannot affect the unit tests (the `changes`
job) skips `report` along with build and test, and the gate passes as before.

A floor is lowered only by an owner decision, never to make a PR pass.

### Small files at full coverage

The tolerance is 1.5 percentage points of a row's lines, which for a small file
is about one line. `DownloadNetworkLossMonitor` has 90 executable lines and a floor of 1.0:
it fails below 98.5%, so one uncovered line reads `WITHIN` and two (88/90)
block the PR. Any file under 67 lines at a floor of 1.0 blocks on a single
line. This is intended for a small, deterministic file that is fully covered.
When it blocks, add a test for the uncovered lines; do not lower the floor.

## Local use

```bash
python3 scripts/enforce_coverage_floors.py coverage-data.json
python3 scripts/enforce_coverage_floors.py coverage-data.json --baseline-only
```

`--baseline-only` compares each row against its own current value, so it prints
the measurements and fails only on a module with no data. It does not modify
the floors file and is not a regression check.

`scripts/verify-pr.sh` runs the enforcer on its own result bundle. On a pass it
records `All blocking floors met`, followed by the number of rows within the
tolerance and advisory rows below their floor when either is non-zero. It does
not collect package source, so its runs compare the app floors only.
