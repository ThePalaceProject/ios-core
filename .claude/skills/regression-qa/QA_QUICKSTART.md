# QA Quickstart — Manual Regression with Claude Code

This is the manual-only regression flow. No simdrive, no automation tooling, no maintainer-only setup. Everything runs from a fresh ios-core clone.

## You'll need

1. **Claude Code** installed (CLI, desktop app, or VS Code extension).
2. **ios-core repo** cloned, on the candidate branch you're testing.
3. **Xcode 26** with an iOS simulator runtime installed.
4. **Two builds:** a baseline build (the version you're comparing against) and a candidate build (the version you're testing). Install both somewhere you can switch between — two simulators, two devices, or a sim + a device.
5. **Test library credentials** — get these from your team's QA credential store. Not in this repo.
6. **(Optional) Jira API access** — required for automatic ticket creation. The skill will walk you through setup if you don't have it. You can also skip and paste tickets manually.

## Run it

In the ios-core directory:

```
/regression-qa PP-XXXX --baseline-version 3.0.0 --candidate-version 3.1.0
```

Replace `PP-XXXX` with your parent Jira ticket and the versions with what you're testing.

## What Claude will do

1. **Pre-flight check** — verifies Xcode, simulator, repo state, and Jira creds. Tells you what's missing before you waste time.
2. **Set up your workspace** at `~/Desktop/regression-PP-XXXX/` with `findings.csv`, `TEST_MATRIX.md`, `ENVIRONMENT.md`, and a `screenshots/` folder.
3. **Walk you through the test matrix** — area by area, P0 → P1 → P2. For each area: tells you the test, asks what you see on baseline, asks what you see on candidate, listens for differences.
4. **Triage anything you find** — searches the codebase, checks git history, finds related Jira tickets, and helps you write a clean repro before logging.
5. **Log findings** to `findings.csv` with proper classification + severity.
6. **Generate an HTML report** with screenshots and evidence.
7. **Create Jira tickets** (dry-run first, real run with your approval).

## What you do

- Switch builds, tap buttons, observe screens — Claude can't do this for you.
- Capture screenshots when you find something. Pair them: baseline + candidate.
- Verify findings on a different device when possible (it changes the report quality).
- Push back if Claude misclassifies something. Final word is yours.

## Where things live

| File / folder | What it is |
|---|---|
| `~/Desktop/regression-PP-XXXX/findings.csv` | Single source of truth for all findings |
| `~/Desktop/regression-PP-XXXX/TEST_MATRIX.md` | Your working copy of the test areas |
| `~/Desktop/regression-PP-XXXX/ENVIRONMENT.md` | Build details, devices, libraries you're testing |
| `~/Desktop/regression-PP-XXXX/screenshots/` | Drop screenshot pairs here, named per the CSV |
| `~/Desktop/regression-PP-XXXX/report/index.html` | The final HTML report |
| `docs/Testing/REGRESSION_TEST_MATRIX.md` | Canonical test matrix in the repo (edit + PR for permanent changes) |

## Adding / modifying scenarios

- **Just for this run:** edit `~/Desktop/regression-PP-XXXX/TEST_MATRIX.md`. The report regenerates from this file.
- **For every future regression:** edit `docs/Testing/REGRESSION_TEST_MATRIX.md` in the repo and open a PR.

Ask Claude to help — it can draft the row in matrix format and put it in the right tier (P0/P1/P2).

## Manual fallback (no Claude)

If Claude isn't available, the same scripts work directly:

```bash
# 1. Setup
scripts/regression-report.sh setup --ticket PP-XXXX --output-dir ~/Desktop/regression-PP-XXXX

# 2. Test manually using ~/Desktop/regression-PP-XXXX/TEST_MATRIX.md as your checklist
#    Log findings to findings.csv (any spreadsheet app)

# 3. Report
scripts/regression-report.sh report \
  --output-dir ~/Desktop/regression-PP-XXXX \
  --baseline-version 3.0.0 \
  --candidate-version 3.1.0 \
  --strict

# 4. Tickets (dry-run shows what would be created)
scripts/regression-report.sh tickets \
  --output-dir ~/Desktop/regression-PP-XXXX \
  --ticket PP-XXXX \
  --dry-run
```

## Tips

- **Don't skip P0.** Auth, borrow, download, DRM. Failure here blocks release.
- **Pre-existing bugs are valuable.** If something is broken in both versions, log it as `pre-existing`. PP-4020 found a 6-year-old blocker this way.
- **Multi-variant rows aren't one test.** A row that says "All 7 auth types" is 7 separate test runs. Don't mark the row done after testing one variant.
- **Verify before reporting.** The `Verified` column prevents false positives from reaching the final report.
- **Screenshots ≤800px wide.** Larger files block report sharing.
