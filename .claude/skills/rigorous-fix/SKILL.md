---
name: rigorous-fix
description: Architect + SoD-review rigor for single-module critical-path changes that don't warrant a full /swarm but DO warrant more than bare /clean-code. Use when touching auth, sign-in, borrow, return, download, DRM fulfillment, audiobook playback, persistence migrations, or any code where a regression would hit users — regardless of LOC count. Invoke via "/rigorous-fix <task>" or when the user says "rigorous fix for X", "do this with SoD review", "critical path change to Y". For multi-module work, use /swarm. For non-critical bug fixes <50 LOC, /clean-code is sufficient.
tools: Agent, Bash, Read, Write, Edit, Grep, Glob, mcp__forgeos__forge_propose_changeset, mcp__forgeos__forge_submit_evidence, mcp__forgeos__forge_check_gates, mcp__forgeos__forge_promote_gate, mcp__forgeos__forge_get_context
# doc-lifecycle metadata (added by Module B sweep)
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
---

# /rigorous-fix — architect + SoD review for single-module critical-path work

## When to use

**Use /rigorous-fix when:**
- A change touches a critical path (see CLAUDE.md "Risk-driven rigor bar") AND
- The change is single-module (so /swarm would be triage-overhead) AND
- The change is non-trivial OR the area is failure-prone

Critical paths per CLAUDE.md:
- `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/` — auth, sign-in, credential storage
- `Palace/MyBooks/Borrow*`, `Palace/MyBooks/BookReturn*`, `Palace/MyBooks/Download*` — borrow / return / download / DRM
- `Palace/Audiobooks/` — audiobook playback (toolkit fragile per memory)
- `Palace/Migrations/` — anything touching persistence schema
- `Palace/Network/TPPNetworkResponder.swift`, `Palace/Network/TPPNetworkExecutor.swift` — auth-error decision points

**Don't use /rigorous-fix when:**
- Multi-module work → use `/swarm`
- Bug fix <50 LOC in a non-critical path → `/clean-code` is sufficient
- 1-LOC typo fix even in critical path → just commit; the change is too small for architect overhead

## Differences from /swarm

| Aspect | /swarm | /rigorous-fix |
|--------|--------|---------------|
| Modules | ≥2 | 1 |
| Implementers | N parallel | 1 (you, the main agent) |
| Architect | Yes (full Phase 0 recon + contracts) | Yes (lighter — read area's verification-checklist.md, produce a fix-contract) |
| Reviewers | architect + qa_test via /forge-review | architect + qa_test via /forge-review |
| Phase 4.5 skeptic pass | Yes | Yes (against your own work) |
| Definition of Done evidence | Required per implementer | Required from you |
| Wall-failure catalog integration | Yes — every block becomes an entry | Yes — every block becomes an entry |
| Worktree isolation | Yes — `.claude/worktrees/swarm_<id>-orchestrator` | Optional — only if concurrent sessions are likely |
| ForgeOS changeset | Yes — registered before code | Yes — registered before code |

## The loop

### Phase 0 — Read the area's verification-checklist

Look up `docs/architecture/areas/<area>/verification-checklist.md` for the touched area. This file is the architect's pre-existing recon — it lists the call-site map, module ownership, dispatch matrix, IdP catalog (for auth), telemetry surface, test inventory, known traps. **Don't skip this. It's why per-area checklists exist.**

If the area doesn't have a verification-checklist yet, you have two options:
1. Build one (treat as scope addition; surface to user)
2. Spawn an architect subagent for ad-hoc recon (smaller than /swarm's Phase 0 — just call-site map + test inventory + known traps for this specific change)

Decision rule: if the change is in an area you've worked in before this session, option 1's cost is small. If first-touch, option 2 is faster.

### Phase 1 — Architect-light: produce a fix-contract

Either you (main agent) OR a spawned Plan subagent produces a fix-contract at `.forgeos/changesets/<branch-name>/fix-contract.md`:

```markdown
# Fix-contract — <task>

## Scope (in)
- File: <path>
- Lines: <range or "function X">
- Behavior change: <what's different after>

## Scope (out)
- File: <path> — DO NOT touch (named explicitly because the area's verification-checklist lists it as related but off-limits)
- ...

## Verification criteria (grep-able assertions before declaring done)
- `grep -c "<SUT>(" <test-file>` ≥ 1
- `grep -E "<pattern of NEW function whose result must be used>" <prod-file>` ≥ count-of-calls
- `grep -rn "<legacy fn name>" Palace/<area>/` returns zero hits post-fix (if migrating)
- Mutation kill ≥ 80% on <changed file> (diff-only)
- Test name multi-step keywords match body multi-step calls

## Tests required
- Behavior tests (must catch regression of the bug being fixed)
- Round-trip wiring test (if state machine — per CLAUDE.md `feedback_round_trip_wiring_tests`)
- Negative case (what happens if X)

## Acceptance
- All Verification criteria pass
- Existing critical-path regression tests stay green
- Mutation rate meets threshold
- verify-pr.sh --quick --diff-baseline PASS
```

### Phase 2 — ForgeOS changeset + Definition of Done

Create the changeset before code:
```
mcp__forgeos__forge_propose_changeset \
  --project_id <pid> --initiative_id <init> \
  --branch <branch> --description "Fix-contract at .forgeos/changesets/<branch>/fix-contract.md"
```

Implement per CLAUDE.md Definition of Done. Paste evidence for all 6 checks in your commit body — same as a swarm implementer would.

### Phase 3 — Skeptic-pass against your own work

You wrote the code. You verify it the same way you'd verify a subagent's work:

```bash
# Run /clean-code (which now includes the skeptic-pass greps in Section J)
# Then run the Verification criteria greps from your fix-contract.
# Then run scripts/verify-pr.sh --quick --diff-baseline
```

If any check fails, fix it BEFORE invoking /forge-review. Don't ask the reviewers to catch what you should have.

### Phase 4 — /forge-review (architect + qa_test SoD)

```
/forge-review
```

Same SoD pattern as /swarm. If BLOCKED:
1. Create a wall-failure entry per `.forgeos/wall-failures/README.md`.
2. Fix the finding.
3. Re-run /forge-review.

### Phase 5 — Promote + commit + PR

Same as /swarm Phase 6. The commit message format:

```
<conventional-prefix>: <task summary>

<details>

ForgeOS changeset: <cs_id>
Fix-contract: .forgeos/changesets/<branch>/fix-contract.md

**Scope:** <what's in>
**Not done:** <what's deferred, if anything>
```

## Why this exists

`/swarm` requires ≥2 modules. `/clean-code` is for any commit. There was no skill in between — but the *risk* of a single-module critical-path change is identical to a multi-module change (both can ship a regression to users). The 50-LOC bar in `/swarm`'s "Don't use when" was structural; `/rigorous-fix` is the risk-based replacement for that class of work.

Without `/rigorous-fix`, a 30-LOC `BookReturnService` change ships through bare `/clean-code` + verify-pr.sh. With it, the same change gets architect-then-SoD-review — the same rigor a 500-LOC multi-module refactor gets.

## Status

**STUB — 2026-05-28.** Skill loaded but not yet exercised on a real critical-path change. First use of /rigorous-fix should be retroactively tested against a known-good prior PR in a critical path (e.g. PR #988 LCP audiobook downgrade) to validate the architect-light + verification criteria flow works at single-module scale. Update `docs/architecture/swarm-rigor-followups.md` with first-use lessons.
