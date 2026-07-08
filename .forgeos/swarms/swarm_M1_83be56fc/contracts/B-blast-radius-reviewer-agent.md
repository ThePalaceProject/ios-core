# Module B — Blast-radius reviewer agent + universal skill routing (M1)

**Critical-path-meta.** New SoD reviewer that runs on every PR + skill routing changes.

## Goal

Ship a new SoD reviewer agent + wire it into 4 skills so every PR (regardless of skill route) gets the blast-radius lens.

## Deliverables

### `.claude/agents/forge-blast-radius-reviewer.md` (NEW)

Mirror the structure of existing `forge-architect-reviewer.md` and `forge-qa-reviewer.md` (located at `~/.claude/agents/`). Single-purpose adversarial reviewer.

**Frontmatter:**
```yaml
---
name: forge-blast-radius-reviewer
description: Independent blast-radius reviewer for ForgeOS changesets. Spawn for ANY PR (universal floor) when changeset's review gate requires blast_radius role. Adversarial single-purpose scope — API surface, #if DEBUG reachability, test-seam bypass, contract-vs-diff drift.
tools: Read, Bash, Grep, Glob, mcp__forgeos__forge_submit_review, mcp__forgeos__forge_check_gates, mcp__forgeos__forge_get_profile, mcp__forgeos__forge_query_mind
model: opus
---
```

**Review criteria (verbatim):**
- What's in the public API surface that shouldn't be (test-only counters, test-only inits)?
- What's gated by `#if DEBUG` that runs outside unit tests (sim, TestFlight, App Store)?
- What test-only code is reachable from production paths?
- What new inits/methods change the framework's public ABI?
- What seams claim to enable injection but are bypassed by callers using static factories?
- What claims in the contract / commit body / PR body are not delivered by the diff?

**Process:** 8 steps — `forge_check_gates`, read diff, read commits/intents/contracts, read CLAUDE.md, run 4 universal scripts as evidence, evaluate against 6 bullets, submit via `forge_submit_review` role=`blast_radius`, report ≤250 words.

**Verdict rules:** approved (no concern/fail findings + all 4 scripts exit 0), blocked (any concern/fail + script exit 1 the reviewer agrees with), pending (cannot evaluate).

**Submit-review schema:** role=`blast_radius`, categories=`surface | debug_reachability | test_seam | abi | injection | claim_drift`.

Target LOC: ~100-130 (architect-reviewer is 113).

### Skill edits (4 files)

**`.claude/skills/clean-code/SKILL.md` — Section J.5 (new):**
```
J.5. Universal rigor scripts (M1 floor)

Run before declaring audit complete:
  python3 scripts/check-contract-reconciliation.py --quiet
  python3 scripts/check-blast-radius.py --quiet
  python3 scripts/check-adjacency-staleness.py --quiet
  python3 scripts/check-intent-recorded.py --quiet

Block commit on contract-reconciliation OR blast-radius exit 1.
Adjacency: warn-only.
Intent: blocks only ≥10 prod LOC.

For ≥10 prod LOC under Palace/, spawn `forge-blast-radius-reviewer` agent (advisory in /clean-code).
```

**`.claude/skills/rigorous-fix/SKILL.md` — 2 edits:**
1. Phase 1a NON-SKIPPABLE for /rigorous-fix (currently optional). Add: "After producing fix-contract, spawn forge-architect-reviewer subagent before proceeding to Phase 2."
2. Phase 4 reviewer list: 2 → 3 (add `blast_radius`).

**`.claude/skills/swarm/SKILL.md` — 3 edits:**
1. Phase 4.5 add Check 6 invoking 4 universal scripts (BLOCK on contract-reconciliation/blast-radius/intent-recorded exit 1; warn-only on adjacency).
2. Phase 5 spawn 3 reviewers (architect + qa_test + blast_radius).
3. Phase 1a NON-SKIPPABLE for any module with `risk: critical_path` or `critical_path_meta`. Skipping permitted ONLY for all-standard swarms with area-checklists.

**`.claude/skills/forge-review/SKILL.md` — 2 edits:**
1. Role-mapping table: add `blast_radius → forge-blast-radius-reviewer`.
2. Top of Process: "0. Universal floor — always include blast_radius regardless of gate requirements."

## Constraints

- Agent file mirrors `~/.claude/agents/forge-architect-reviewer.md` structure verbatim where applicable.
- Skill edits are SURGICAL — do not rewrite sections, insert in-place.
- Path string coordination with Module A: agree the 4 script paths up front (per Contract A: `scripts/check-{contract-reconciliation,blast-radius,adjacency-staleness,intent-recorded}.py`).

## Files OFF-LIMITS

- All `scripts/check-*.py` (Module A owns)
- `CLAUDE.md`, `scripts/verify-pr.sh`, `scripts/git-hooks/pre-commit`, `.claude/skills/intent/` (Module C owns)
- All `Palace/*`, `PalaceTests/*`

## Definition of Done (paste in transcript)

1. SUT instantiation N/A (Markdown spec).
2. Function-result N/A.
3. Multi-step body — 8-step Process section in agent file.
4. Scope coverage — 1 agent file + 4 skill edits.
5. Mutation pass — shellcheck the new bash blocks in skill edits; confirm `||` exit-code handling.
6. Build — agent file passes `Read` test; skill files parse cleanly.
7. N/A.

## Implementer prompt

You are Module B of swarm_M1_83be56fc. cd to `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_M1_83be56fc-B-blast-radius-reviewer-agent`. Build the new agent file matching `~/.claude/agents/forge-architect-reviewer.md`'s structure verbatim (read it FIRST). Then make the 4 skill edits per this contract — SURGICAL inserts only, do not rewrite existing sections. Module A is working on the 4 scripts in parallel; reference them by path-string only (no exec dependency). Paste all DoD checks in transcript before READY.
