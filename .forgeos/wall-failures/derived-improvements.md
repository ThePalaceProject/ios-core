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
| 2026-05-27 | Per-area verification checklists (auth first) — becomes architect's first-deliverable reference | arch3, qa2, qa3 (auth-area-specific) | docs/architecture/areas/auth/verification-checklist.md (this PR) | partial — auth only; other 7 areas pending |
| 2026-05-27 | scripts/verify-pr.sh --diff-baseline for auto-flake comparison | implicit (orchestrator handwaved 9 "pre-existing flakes") | verify-pr.sh patch (this PR) | applied |

## How this file gets updated

When you apply a derived improvement:
1. Add a row above with date, improvement, source entries, implementation link, status.
2. Update the source `wall-failures/*.md` entries' frontmatter `status: applied` + `applied_in: <PR or commit>`.
3. Update `INDEX.md` to reflect the new status.

If a derived improvement gets reverted or proves ineffective (a later swarm sees the same finding class recur), add a "regression" row with the entry that proves the system didn't actually close the gap.
