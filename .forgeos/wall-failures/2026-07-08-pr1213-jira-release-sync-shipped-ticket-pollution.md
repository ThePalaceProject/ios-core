---
date: 2026-07-08
pr: "#1213"
source: shipped-bug
reviewer_ids: []
changeset_id: ""
wall: hook
walls: [verify-pr, stale-doc]
severity: medium
wall_status: applied
applied_in: "fix/jira-release-sync-skip-shipped-tickets"
detector_script: ""
detector_status: no-detector
no-detector: "The failure is a runtime side effect of the release CI pipeline (a Jira write), not a pattern in a code diff. No PR-diff scanner can catch it — the structural fix is a runtime guard inside jira-release-sync.yml, verified by an inline shell unit-test, not a static check over changed files."
contributing_docs:
  - path: docs/architecture/release-merge-policy.md
    last_refresh_at_failure: 2026-05-26
    decay_days: 43
name: jira-release-sync-shipped-ticket-pollution
type: evolving
status: active
created: 2026-07-08
last_refresh: 2026-07-08
freshness_window: 365d
owners: [general]
description: 3.2.0 release-on-merge stamped iOS 3.2.0 fixVersion onto 15 already-shipped tickets (ReleaseNotes.py over-inclusion × unguarded jira-release-sync)
---

# jira-release-sync stamped 15 already-shipped tickets with iOS 3.2.0

## Finding (verbatim from bug report)

Promoting `release/3.2.0` → `main` fired `release-on-merge.yml` → `jira-release-sync.yml`, which added `fixVersion = iOS 3.2.0` to **15 tickets that had already shipped in iOS 3.0.0 / 1.2.1** (PP-1085, PP-3452, PP-3592, PP-3838, PP-3907, PP-3957, PP-3969, PP-4020, PP-4033, PP-4045, PP-4065, PP-4115, PP-4116, PP-4117, PP-4168). Each was `Done` and already carried an earlier `iOS *` fixVersion. This is the exact pollution class the 3.1.0 post-mortem flagged as "narrowly avoided" — this time the auto-chain fired.

## What actually happened

`ReleaseNotes.py` (`baseline_tag()` → `git log <last-tag>..HEAD`) collects **every** `PP-####` key mentioned in **any** commit in range, including keys referenced in passing by newer commits (regression campaigns, follow-up work, "revisit PP-XXXX" messages). A release merge commit brings a whole cycle's commits into `baseline..HEAD`, so old ticket keys get swept into the generated release body. `jira-release-sync.yml` then greps that body for `PP-\d+` and unconditionally `add`s the new `fixVersion` to **every** key — no check for whether the ticket already shipped. Result: already-released tickets get a second, wrong iOS fixVersion, corrupting "what's in iOS 3.2.0" reporting.

It looked correct because the release body IS a legitimate changelog and every key in it is real; nothing distinguishes "new work this release" from "mentioned this release."

## Walls that should have caught it (and why they didn't)

- **verify-pr / hook**: the release-notes + Jira-sync path is release-CI automation, not a code diff, so none of the PR-time walls (contract/TDD/mutation/verify-pr/hook) run against it. The pipeline had no self-check on its own output.
- **stale-doc**: `docs/architecture/release-merge-policy.md` (2026-05-26) already listed "improve `ReleaseNotes.py` to walk merge-commit second-parent history so ticket attribution survives" as an unchecked, "separate ticket; not blocking" item. The known gap was documented but never closed, and 43 days later it fired.

## Proposed permanent fix (applied)

Add a **guard in `jira-release-sync.yml`'s "Update fixVersions" step**: before adding `iOS <new>` to a ticket, fetch its current `fixVersions`; if it already carries any `iOS *` version **other than** the one being applied, **skip** it (it was attributed to an earlier release — this is a re-mention, not new work). Emits a `skipped(already-shipped)` count in the step summary so the decision is auditable in the run log.

This makes the pollution class **structurally impossible**: an already-shipped ticket can never receive a second iOS fixVersion from the release sync, regardless of how over-broad `ReleaseNotes.py`'s output is. The GitHub release **body** can still over-list (cosmetic), but the Jira reporting surface — the one that actually matters — stays clean.

Deeper root-cause follow-up (tracked, separate repo): tighten `ReleaseNotes.py` in `mobile-certificates` so the changelog itself only attributes keys that appear in a genuine PR-merge/squash subject, not arbitrary commit-body mentions. That fixes the cosmetic body over-inclusion too.

## No detector — justification

See `no-detector` frontmatter: the defect is a runtime Jira write in release CI, not a code-diff pattern, so a PR-diff scanner cannot encode it. The structural fix is the runtime guard itself, verified by an inline shell unit-test (SKIP/SKIP/ADD/ADD/ADD/SKIP against representative `fixVersions` states) run before landing. The guard's own `skipped=` summary line is the ongoing runtime signal.

## Immediate cleanup performed

- Removed `iOS 3.2.0` from the 15 already-shipped tickets (preserving each ticket's real prior versions).
- Stripped the 15 lines from the GitHub `3.2.0` release notes, restoring the correct 56-ticket set.
