---
name: wall-failures-derived-improvements
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: Derived improvements
---

# Derived improvements

Cluster-level fixes promoted from wall-failure entries. Each row links back to the entries that motivated it.

| Date | Improvement | Source entries | Implementation | Status |
|------|-------------|----------------|----------------|--------|
| 2026-05-27 | Orchestrator skeptic pass (Phase 4.5) in swarm SKILL.md — grep checks for SUT instantiation, function-result usage, scope coverage, claim verification | arch3, qa1, qa2, qa3 | swarm SKILL.md edit (this PR) | applied |
| 2026-05-27 | Verification criteria section required in every architect contract | arch2, arch3, qa2, qa3 | swarm SKILL.md contract template edit (this PR) | applied |
| 2026-05-27 | Implementer self-check checklist mandated in prompt template | qa1, qa2, qa3, arch3 | swarm SKILL.md implementer prompt edit (this PR) | applied |
| 2026-05-27 | Scope-deferral protocol (STOP+report instead of partial-ship) | arch3 (Module C 2-of-7 deferral) | swarm SKILL.md + CLAUDE.md (this PR) | applied |
| 2026-05-27 | Mutation-as-implementer-completion-gate | qa1 (half-done test) | swarm SKILL.md (this PR) | applied |
| 2026-05-27 | Definition of Done with literal grep evidence in CLAUDE.md — applies to single-agent and swarm | all 6 entries | CLAUDE.md edit (this PR) | applied |
| 2026-05-27 | Risk-driven rigor bar — critical-path changes get architect+SoD review regardless of LOC | implied by all 6 entries (some were small-LOC critical-path) | CLAUDE.md + /rigorous-fix skill stub (this PR) | partial — skill stubbed |
| 2026-05-27 | /clean-code extended with skeptic-pass greps for single-agent commits | qa2, qa3, arch3 | .claude/skills/clean-code/SKILL.md edit (this PR) | applied |
| 2026-05-27 | Per-area verification checklists (auth first) — becomes architect's first-deliverable reference | arch3, qa2, qa3 (auth-area-specific) | docs/architecture/areas/auth/verification-checklist.md (this PR) | applied |
| 2026-05-28 | Per-area verification checklists — 7 remaining areas (audiobook, mybooks, reader, network, accounts, signin-modal, holds) | A1 of followups; PR #1018 architect re-discovery cost | docs/architecture/areas/{audiobook,mybooks,reader,network,accounts,signin-modal,holds}/verification-checklist.md (this PR, second pass) | applied |
| 2026-05-27 | scripts/verify-pr.sh --diff-baseline for auto-flake comparison | implicit (orchestrator handwaved 9 "pre-existing flakes") | verify-pr.sh patch (this PR) | applied |
| 2026-05-28 | Public-surface drift pre-commit hook (A2) | implicit — public surface drift without contract update is a class we haven't seen escape yet but the pattern fits qa2/qa3 (fake doc-of-truth) | ~/harness/core/hooks/pre-public-surface-drift.sh + scripts/hooks symlink + .claude/settings.json registration | applied |
| 2026-05-28 | Critical-path mutation pre-commit hook (A3) | qa1 (half-done test that mutation would have killed if it'd been run) | ~/harness/core/hooks/pre-critical-path-mutation.sh + symlink + settings.json | applied |
| 2026-05-28 | Architect post-review enforcement in swarm manifest schema (A4) | PR #1018 architect under-estimated test surface 7x (48 → 385+) — no SoD on the architect's own output | .forgeos/schemas/swarm-manifest-v2.md + swarm SKILL.md Phase 4.5 Check 0 | applied |
| 2026-05-28 | Critical-path pre-push review hook + policy (B5) — /forge-review mandatory for critical-path PRs regardless of swarm/single-agent origin | B3 backtest 0% catch finding + risk-driven-bar concept (CLAUDE.md) | ~/harness/core/hooks/pre-push-critical-path-review.sh + symlink + .claude/settings.json + docs/architecture/critical-path-review-policy.md | applied |
| 2026-05-28 | Production observability → SessionStart context (C2 STUB) | implicit — production signal currently doesn't auto-flow to next session | docs/architecture/session-observability-context.md (design + scaffolding); full hook impl deferred pending file-about-to-be-edited inference design | partial — stubbed |
| 2026-05-28 | Harness helper scripts for swarm Phase 4.5 (A5) — run-contract-verification.py + migration-completeness-check.py | swarm SKILL.md references the scripts; Phase 4.5 needs them to mechanically verify contracts + catch fake migrations | ~/harness/core/lib/run-contract-verification.py + migration-completeness-check.py (harness repo) | applied — smoke-tested against PR #1018 artifacts (contract-verification: 0/0 — existing contracts predate Verification-criteria convention; migration-completeness: 13 findings, mostly comment-line false-positives + 1 real legacy retain that's intentional) |
| 2026-05-28 | B3 backtest — paper analysis of 10 prior shipped Palace iOS bugs vs SoD reviewer prompts | wall-failure META calls for measuring whether reviewers actually catch real bugs, not just process-discipline issues | .forgeos/wall-failures/backtest-2026-05-28.md (this PR) | applied; 0% definitive WOULD-CATCH on shipped bugs; top 5 reviewer-prompt additions ranked (#1 mandatory SharedMind queries for high-risk modules; #2 structural-sibling sweep clause; #3 switch-exhaustiveness for closed enums; #4 Swift-concurrency continuation audit; #5 persisted-state cold-launch clause) |

## What the B3 backtest changes about my model

**Before B3:** I assumed the SoD reviewer agents had broad coverage. PR #1018 demonstrated they catch real issues (fake migrations, fake test instantiation, half-done tests).

**After B3:** They catch *process-discipline* issues well; they catch *domain-knowledge* issues poorly. The 0% definitive WOULD-CATCH on 10 prior shipped bugs is a calibration data point — the reviewers are NOT a universal safety net. They're a specific safety net for "dishonest work patterns" but not for "missed structural sibling cases" or "Swift concurrency footguns" or "SharedMind references the lesson but the reviewer prompt doesn't reach for it."

**Implication:** the top 5 prompt additions from B3 should themselves become a follow-up. Adding "mandatory SharedMind query for `<area>` when reviewing a `<area>` change" to the reviewer prompts would convert most WOULDN'T-CATCH cases to WOULD. This is the highest-leverage follow-up after this PR ships.

## How this file gets updated

When you apply a derived improvement:
1. Add a row above with date, improvement, source entries, implementation link, status.
2. Update the source `wall-failures/*.md` entries' frontmatter `status: applied` + `applied_in: <PR or commit>`.
3. Update `INDEX.md` to reflect the new status.

If a derived improvement gets reverted or proves ineffective (a later swarm sees the same finding class recur), add a "regression" row with the entry that proves the system didn't actually close the gap.
