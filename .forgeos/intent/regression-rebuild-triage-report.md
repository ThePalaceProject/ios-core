# Intent: RC-TRIAGE+REPORT (regression-rebuild campaign, stages 4–5)

**Branch:** `feat/regression-rebuild-triage-report` (off `develop`)
**Owner:** w-triage · **Coordinator:** palace-pm
**Design refs:** `palace-pm/docs/REGRESSION-REBUILD-DESIGN.md §4.3 stages 4–5`,
`REGRESSION-BUILD-PLAN.md` (shared contracts).

## Claims (what this change adds)
1. Adds `scripts/regression-triage.py` — a deterministic triage harness that
   reads a campaign `findings.csv` (shared contract schema) and writes back the
   four triage fields `severity`, `classification`, `dedup_cluster`,
   `disposition`. Rule-based pre-classifier attributes each finding to the
   test-isolation pollution taxonomy + finding-type enum; computes dedup
   clusters by root-cause signature; assigns severity; assigns disposition via
   the `-test-iterations 3` green@3/red@3 + verified discriminator.
2. Adds `scripts/regression-triage.py` Fable-bridge: emits a per-finding
   Fable-input JSON bundle (`--emit-fable-input`) and ingests a Fable-output
   JSON (`--apply-fable`) so a `model: fable` subagent refines the deterministic
   baseline. The harness degrades to the deterministic classification if no
   Fable output is supplied.
3. Adds `scripts/regression-fable-triage-agent.md` — the `model: fable`
   subagent spec (the Fable-triage stage) with the exact input/output JSON
   contract the harness produces/consumes. (`.claude/` is gitignored in
   ios-core, so the canonical spec lives in `scripts/` and is symlinked into
   `.claude/agents/` locally for spawnability.)
4. Adds `scripts/generate-regression-campaign-report.py` — consumes the
   post-triage contract-schema `findings.csv` → self-contained HTML report with
   a device/OS coverage matrix, dedup-cluster grouping, taxonomy + severity
   breakdown, a visual-diff gallery (`screenshot_pair`), and evidence links.
5. Adds `scripts/tests/test_regression_triage.py` and
   `scripts/tests/test_regression_campaign_report.py` (pytest) + a sample
   `scripts/tests/fixtures/regression-findings-sample.csv`.

## Anti-claims (explicitly NOT in scope here)
- Does NOT define or own the `findings.csv` schema or the shared
  `scripts/regression_findings.py` I/O module — that is w-stabilize's
  (RC-AREA). This change reads/writes findings exclusively via that module
  (`read_findings`/`write_findings`/`FINDINGS_COLUMNS`/`FINDING_CLASSIFICATIONS`)
  now that #1076 has landed it on develop; no parallel CSV reader/writer is
  hand-rolled here (BUILD-PLAN contract). (Pre-rebase the branch carried a
  schema-identical fallback so it could build before the module landed; the
  rebase onto develop dropped it.)
- Does NOT modify the existing `scripts/generate-regression-report.py`
  (old-schema `/regression` report) — the campaign report is a new file.
- Does NOT call the ForgeOS MCP directly. The changeset hook (harness, local-only
  per IP boundary) emits a deterministic changeset *plan*; the coordinator
  executes `forge_propose_changeset`.
- No Palace/ production code changes. No new public Swift API surface.

## Files-in-scope (ios-core)
- `scripts/regression-triage.py` (new)
- `scripts/generate-regression-campaign-report.py` (new)
- `scripts/regression-fable-triage-agent.md` (new; symlinked into `.claude/agents/` locally)
- `scripts/tests/test_regression_triage.py` (new)
- `scripts/tests/test_regression_campaign_report.py` (new)
- `scripts/tests/fixtures/regression-findings-sample.csv` (new)
- `.forgeos/intent/regression-rebuild-triage-report.md` (this file)

## Out-of-tree (harness, local-only — Synctek orchestration IP)
- `~/harness/stacks/ios/regression-campaign/changeset-hook.py` — the ForgeOS
  changeset-per-real-regression hook (emits the changeset plan).

## Verification plan
- pytest the triage harness on the sample csv: classification + severity +
  dedup_cluster + disposition all populated; pollution classes get
  `ticket-as-flake`/`drop`, real verified regressions get `file-jira`.
- pytest the report generator: HTML written, contains the coverage matrix +
  every cluster + severity/taxonomy counts.
- `bash -n` clean (no shell here; python `-m py_compile`).
- Open a ForgeOS changeset; SoD `/forge-review` on a different model; coordinator
  clean-worktree re-verify before merge.
