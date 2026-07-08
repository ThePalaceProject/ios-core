# Module A — Phase 3.5 META-TOOLING rollout

**Status:** READY
**Date:** 2026-06-05
**Implementer:** Module A subagent
**Branch:** swarm/swarm_162a3219-scaffold (orchestrator worktree)

## Summary

- Inserted new Phase 3.5 (class scan + detector codify) section into `/rigorous-fix` SKILL.md between Phase 3 (skeptic-pass) and Phase 4 (forge-review). Defines the 5-step loop (characterize → scan → triage → wipe → codify-detector), the 3-tier mechanism (grep / Explore subagent / dedicated script), and the non-negotiable discipline guardrails (scope-deferral protocol, triage budget by class size, detector-over-wipe preference).
- Cross-referenced Phase 3.5 into `/swarm` SKILL.md as a Phase 4.0a integrator class-scan reconciliation step + Phase 4.5 check 6.4 (blocks integration if a transcript records a `class_scan:` block without either a detector script reference or a scope-deferral followup ticket).
- Added "Detector requirement" subsection to `.forgeos/wall-failures/README.md` — every entry MUST land with `detector_script: scripts/check-<wall-id>.py` OR `no-detector: <specific reason>` in frontmatter, plus a `detector_status:` enum (built / queued / no-detector).
- Added new `## Detector script` body section + frontmatter fields (`detector_script:`, `detector_status:`, `no-detector:`) to `.forgeos/wall-failures/TEMPLATE.md`.
- Created new architecture doc `docs/architecture/phase-3.5-class-scan.md` explaining the rationale, the 5-step loop + 3-tier mechanism, the 6 detectors landed in swarm_162a3219, and the cluster-vs-instance decision rule.
- Added a derived-improvements.md row recording Module A as the cluster-level fix.
- Added a single 2-line cross-reference in `CLAUDE.md`'s "Wall-failure catalog" section pointing to `/rigorous-fix` Phase 3.5 and the new detector-required convention. Per contract: this is the only CLAUDE.md edit.

## Files modified / added

**Modified:**
- `.claude/skills/rigorous-fix/SKILL.md` — inserted Phase 3.5 section between Phase 3 and Phase 4; added 1-line loop-overview cross-reference; tightened Phase 4 wall-failure-entry bullet to require detector_script per Phase 3.5
- `.claude/skills/swarm/SKILL.md` — inserted Phase 4.0a paragraph in Phase 4 (Integrate) cross-referencing Phase 3.5; added Phase 4.5 check 6.4 (class-scan reconciliation) as a hard BLOCK gate
- `.forgeos/wall-failures/README.md` — new "Detector requirement (2026-06-05, swarm_162a3219)" subsection under Workflow with frontmatter schema example
- `.forgeos/wall-failures/TEMPLATE.md` — added `detector_script:`, `detector_status:`, `no-detector:` frontmatter fields + new `## Detector script` body section before `## Stale-doc contribution`
- `.forgeos/wall-failures/derived-improvements.md` — added 1 row at top of cluster-fix table
- `CLAUDE.md` — single 2-line cross-reference paragraph added below "This is how the system gets less leaky over time."

**Added:**
- `docs/architecture/phase-3.5-class-scan.md` — new standalone architecture doc (~130 lines)

**Out-of-scope (NOT modified, per contract):**
- `scripts/verify-pr.sh` — integrator wire-in surface; Module B owns it. Reported desired wire-in lines in `gaps` below.
- `.claude/settings.json` — same as above.
- All Module B / D1-D5 detector scripts (own contracts).
- Any Palace/ Swift production file.
- Existing wall-failure entry markdowns (per contract — convention applies forward; backfill is a separate pass).
- `.forgeos/wall-failures/INDEX.md` (per contract — updated separately as new entries land).

## Decisions

1. **Architecture-doc structure** — followed the existing pattern in `docs/architecture/critical-path-review-policy.md` and `docs/architecture/superpartner-spectrum.md`: short "The rule" preamble, the operational checklist linked back to the SKILL.md, then rationale + decision log + a related-pattern crosslink table. Kept the doc to ~130 lines (target was ~60-90 per contract; ran longer because the 6-detector table is load-bearing and I wanted the cluster-vs-instance rule documented in one place).

2. **CLAUDE.md edit scope** — strictly held to 2 lines (one paragraph). The contract explicitly limited this to avoid bikeshedding in the most-read section. The substantive guidance lives in `/rigorous-fix` Phase 3.5 + the new architecture doc; CLAUDE.md just points there.

3. **Phase 3.5 word budget** — final section is 604 words (target was ≤800), well under budget. The doc is dense but each guardrail clause is load-bearing per the contract.

4. **swarm/SKILL.md placement** — added Phase 4.0a paragraph in the Phase 4 (Integrate) section rather than rewriting Phase 1a, because the implementer's class-scan happens after their work lands (post-Phase 3 dispatch), not at architect-triage time. Phase 4.5 check 6.4 is the structural BLOCK gate that pairs with the paragraph — without the runnable check, the paragraph would just be docs.

5. **TEMPLATE.md `detector_script:` is empty-string-not-omitted by default** — chose explicit empty string + `detector_status: no-detector` over omitting the field to make missing-detector evidence visible in `grep` audits across the catalog. Same pattern as `applied_in: ""` already present in the template.

6. **Detector-required convention applies forward, not retroactively** — per the contract's out-of-scope clause, Module A does NOT retrofit existing entries. The `derived-improvements.md` row notes this; a future pass can backfill the ~15 existing entries when convenient.

## Gaps (orchestrator must handle)

### Wire-in stanzas for `scripts/verify-pr.sh` (Module B's surface)

The contract assigns `verify-pr.sh` to the integrator / Module B. The Phase 3.5 detectors landed by this swarm (B + D1-D5) all need a `run_m1_check` block in verify-pr.sh. Suggested template:

```bash
# Phase 3.5 detector — foreign-host 401 scoping (Module B)
run_m1_check "foreign-host-401" \
  "Foreign-host 401 attributed to current account session" \
  "python3 scripts/check-foreign-host-401-scoping.py --scan Palace/ --quiet"

# Phase 3.5 detector — LCP acquisition-chain recursion (D1)
run_m1_check "lcp-acquisition-recursive" \
  "Non-recursive defaultAcquisition.type predicates" \
  "python3 scripts/check-lcp-acquisition-recursive.py --scan Palace/ --quiet"

# ... D2-D5 follow the same shape
```

Each block lands in both the `--quick` codepath and the full codepath. Integrator should serialize the 6 detector blocks in alphabetical-by-wall-id order (B, D1, D2, D3, D4, D5) to avoid implementer collisions.

### Wire-in stanzas for `.claude/settings.json` PreToolUse hooks

Each Phase 3.5 detector also needs a PreToolUse Bash hook entry. Suggested template (one entry per detector under the existing `Bash` matcher's `hooks` array):

```json
{
  "type": "command",
  "command": "python3 scripts/check-foreign-host-401-scoping.py --quiet",
  "timeout": 5,
  "statusMessage": "Checking foreign-host 401 scoping..."
}
```

Same insertion-order convention (alphabetical by wall-id). Integrator should batch the 6 hook entries in one settings.json edit to keep diff cleanliness.

### `.forgeos/wall-failures/INDEX.md`

Per contract, Module A does NOT touch INDEX.md. The new entries that B + D1-D5 create as part of their detectors will need one-line summaries in INDEX.md at integration time — left to the integrator.

### Module B's existing-entry retrofit

The contract notes (and architect-review #5 in `risk highlights` confirms) that Module B's backfill of the existing `2026-06-05-pr1018-icarus-cross-host-logout.md` entry to add `detector_script: scripts/check-foreign-host-401-scoping.py` is the ONLY edit to an existing wall-failure entry across this swarm. That's an intentional in-scope retrofit for Module B; Module A's "no retrofit" clause means *Module A does not retrofit*, not that retrofits are globally banned.

## Definition of Done evidence

Applicable checks for this docs-only module:

| Check | Result | Evidence |
|---|---|---|
| 1. SUT instantiation | N/A | no test classes touched |
| 2. Function-result usage | N/A | no production code |
| 3. Multi-step test body | N/A | no tests |
| 4. Scope coverage audit | PASS | all 6 contract files modified or added as scoped; out-of-scope items explicitly NOT touched (see "Files" section above) |
| 5. Mutation pass | N/A | docs-only |
| 6. Build verification | N/A | docs-only; no compile units changed |
| 7. Blast-radius | PASS | `python3 scripts/check-blast-radius.py --quiet` → exit 0 |
| 8. Adjacency staleness | N/A | not applicable to new docs; no production type renames |
| 9. Superpartner spectrum | PASS | `python3 scripts/check-superpartner-spectrum.py --quiet` → exit 0 |

### Greppable verification criteria (contract section)

| # | Command | Threshold | Actual |
|---|---|---|---|
| 1 | `grep -c "Phase 3.5" .claude/skills/rigorous-fix/SKILL.md` | ≥ 4 | **5** PASS |
| 2 | `grep -cE "Phase 3.5\|class.scan" .claude/skills/swarm/SKILL.md` | ≥ 2 | **9** PASS |
| 3 | `grep -cE "detector_script\|no-detector" .forgeos/wall-failures/README.md` | ≥ 3 | **7** PASS |
| 4 | `grep -cE "detector_script\|## Detector script" .forgeos/wall-failures/TEMPLATE.md` | ≥ 2 | **2** PASS |
| 5 | `grep -E "phase-3.5-class-scan" docs/architecture/ -rln` | ≥ 1 | **1** PASS (`docs/architecture/phase-3.5-class-scan.md`) |
| 6 | `python3 scripts/check-contract-reconciliation.py --quiet` | exit 0 | deferred to commit-msg time (integrator) |
| 7 | `python3 scripts/check-blast-radius.py --quiet` | exit 0 | **exit 0** PASS |

### Word-count budget

Phase 3.5 section in `rigorous-fix/SKILL.md`: **604 words** (budget: ≤800). PASS.

## Notes for integrator

- All changes staged but NOT committed per contract. Integrator runs the commit at Phase 5 with the consolidated commit-msg referencing all 9 modules.
- The Phase 3.5 convention is documented; the 5 D-detector implementers + Module B can reference the wall-failure-entry frontmatter convention before Module A's docs merge (architect-review confirmed all 9 modules can dispatch in parallel — Module A is a "soft dependency").
- One pre-existing worktree gotcha surfaced: `.claude/worktrees/swarm_162a3219-orchestrator/scripts/hooks/` was missing as a symlink. I created `scripts/hooks → /Users/mauricework/PalaceProject/ios-core/scripts/hooks` so the `audit-before-assert.py` PreToolUse hook resolves. Worth a note in `feedback_worktree_palace_setup.md` for the next swarm bootstrap.

## Acceptance

- All 5 grep-able verification criteria PASS
- Blast-radius and superpartner-spectrum checks PASS
- All 6 contract-scoped files modified or added; no out-of-scope edits
- Phase 3.5 section under word budget (604 / 800)
- READY for integration
