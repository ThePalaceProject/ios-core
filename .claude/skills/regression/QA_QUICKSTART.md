---
name: regression-qa-quickstart
type: evolving
status: active
created: 2026-04-29
last_refresh: 2026-04-29
freshness_window: 365d
owners: [general]
description: QA Quick Start — Regression Testing with Claude Code
---

# QA Quick Start — Regression Testing with Claude Code

## Prerequisites

1. **Claude Code** installed (CLI, desktop app, or IDE extension)
2. **ios-core repo** cloned and on the branch you're testing
3. **Two devices or simulators** — one with baseline build, one with candidate build
4. **Test library credentials** — A1QA: `01230000000237 / Lyrtest123`

## Running a Regression

Open Claude Code in the ios-core directory and type:

```
/regression PP-XXXX --baseline-version 2.2.5 --candidate-version 3.0.0
```

Replace `PP-XXXX` with your Jira ticket number.

Claude will:
1. **Set up your workspace** at `~/Desktop/regression-PP-XXXX/`
2. **Run automated tests** (sync, push notifications, mutation testing)
3. **Walk you through manual testing** — area by area, asking what you see
4. **Help you log findings** to the CSV with proper classification and severity
5. **Generate an HTML report** with screenshots and evidence
6. **Create Jira tickets** for regressions and pre-existing bugs (with your approval)

## What You'll Need to Do

- **Test on device.** Claude guides you, but you're the one tapping buttons and comparing screens.
- **Capture screenshots.** When you find something, take a screenshot pair (baseline + candidate).
- **Verify findings.** Claude will ask you to confirm each finding is real before including it in the report.

## Manual Alternative (without Claude Code)

If you prefer to run the process manually:

```bash
# 1. Setup workspace
scripts/regression-report.sh setup --ticket PP-XXXX --output-dir ~/Desktop/regression-PP-XXXX

# 2. Run automated tools
scripts/regression-report.sh auto --output-dir ~/Desktop/regression-PP-XXXX

# 3. Test manually using TEST_MATRIX.md as your checklist
# 4. Log findings to findings.csv (use any spreadsheet app)

# 5. Generate report
scripts/regression-report.sh report --output-dir ~/Desktop/regression-PP-XXXX \
  --baseline-version 2.2.5 --candidate-version 3.0.0 --strict

# 6. Generate Jira tickets (dry-run first!)
scripts/regression-report.sh tickets --output-dir ~/Desktop/regression-PP-XXXX \
  --ticket PP-XXXX --dry-run
```

## CSV Format

When logging findings to `findings.csv`, use these columns:

| Column | Example | Required |
|--------|---------|----------|
| ID | F-001 | Yes |
| Title | Account screen lost nav title | Yes |
| Area | A1 | Yes (from TEST_MATRIX.md) |
| Test ID | A1-01 | Optional |
| Classification | regression | Yes |
| Severity | major | Yes |
| Verified | true | Yes (default: false) |
| Baseline Behavior | Shows "Account" as nav title | Yes |
| Candidate Behavior | Nav title missing | Yes |
| Steps | Settings > Libraries > A1QA | Yes |
| Screenshot Baseline | F-001-baseline-account.png | Recommended |
| Screenshot Candidate | F-001-candidate-account.png | Recommended |
| Notes | VoiceOver impact | Optional |
| PR | 834 | If fixed |
| Jira Ticket | | Filled by ticket generator |

## Tips

- **Don't skip P0 areas.** These are the critical paths — auth, borrow, download, DRM.
- **Pre-existing bugs are valuable too.** If something is broken in both versions, log it. PP-4020 found a 6-year-old blocker this way.
- **Compress screenshots.** 800px wide is plenty. Videos at 720p. Large files block report publishing.
- **Verify before reporting.** The `verified` column prevents false positives. PP-4020 had a 9.6% false positive rate before adding this check.
