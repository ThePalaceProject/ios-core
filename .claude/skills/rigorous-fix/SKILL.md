---
name: rigorous-fix
description: Architect + SoD-review rigor for single-module critical-path changes that don't warrant a full /swarm but DO warrant more than bare /clean-code. Use when touching auth, sign-in, borrow, return, download, DRM fulfillment, audiobook playback, persistence migrations, or any code where a regression would hit users — regardless of LOC count. Invoke via "/rigorous-fix <task>" or when the user says "rigorous fix for X", "do this with SoD review", "critical path change to Y". For multi-module work, use /swarm. For non-critical bug fixes <50 LOC, /clean-code is sufficient.
tools: Agent, Bash, Read, Write, Edit, Grep, Glob, mcp__forgeos__forge_propose_changeset, mcp__forgeos__forge_submit_evidence, mcp__forgeos__forge_check_gates, mcp__forgeos__forge_promote_gate, mcp__forgeos__forge_get_context
# doc-lifecycle metadata (added by Module B sweep)
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-06-05
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
| Reviewers | architect + qa_test + blast_radius via /forge-review | architect + qa_test + blast_radius via /forge-review |
| Phase 4.5 skeptic pass | Yes | Yes (against your own work) |
| Definition of Done evidence | Required per implementer | Required from you |
| Wall-failure catalog integration | Yes — every block becomes an entry | Yes — every block becomes an entry |
| Worktree isolation | Yes — `.claude/worktrees/swarm_<id>-orchestrator` | Optional — only if concurrent sessions are likely |
| ForgeOS changeset | Yes — registered before code | Yes — registered before code |

## The loop

The phases run in order: 0 (recon) → 1 (fix-contract) → 1a (architect-review) → 2 (changeset) → 3 (skeptic) → **3.5 (class scan + detector codify, when a bug-class is identified)** → 4 (forge-review) → 5 (promote). Phase 3.5 is conditional but, when it fires, non-skippable — see `docs/architecture/phase-3.5-class-scan.md` for the rationale.

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
- For every new try await / await boundary added in production code, the contract must include a grep showing a test that drives that exact line via the public entry point. If no such grep is possible (entry point requires unmockable dependencies), STOP with BLOCKED + scope-deferral; the partial test does NOT satisfy the contract. (Catches the swarm_c8fcab76 arch1 pattern — `PlaybackReadinessGate.awaitReadinessAndPlay` called from `AudiobookSessionManager.swift:684-710` but tests drove the static method directly because `openAudiobook(...)`'s mock book failed in the loader before `bind()` ran.)

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

### Phase 1a — Architect post-review (NON-SKIPPABLE for /rigorous-fix)

After producing the fix-contract, **spawn `forge-architect-reviewer` subagent before proceeding to Phase 2**. The architect-reviewer reads the fix-contract, the area's verification-checklist, and the current diff (if any code is staged) and emits an APPROVED / BLOCKED verdict.

This phase was OPTIONAL prior to 2026-05-28 — swarm `swarm_M1_83be56fc` made it MANDATORY for /rigorous-fix because critical-path work is exactly the class where a bad contract propagates into a hard-to-revert regression. The architect can be wrong; the architect-reviewer is your second pair of eyes BEFORE you touch code.

Spawn pattern:

```
Agent
  subagent_type: forge-architect-reviewer
  description: Architect post-review of <task> fix-contract
  prompt: |
    project_id: <pid>
    changeset_id: (pre-changeset — not yet created; refer to fix-contract path)
    branch: <branch>
    worktree_path: <pwd>
    base_ref: origin/develop

    Read the fix-contract at .forgeos/changesets/<branch>/fix-contract.md.
    Read the area's verification-checklist at docs/architecture/areas/<area>/verification-checklist.md (if present).
    Verify:
      1. The fix-contract's scope matches the codebase reality (run greps the contract cites).
      2. Off-limits lists are complete — sibling patterns not silently in scope.
      3. Verification criteria are syntactically valid and catch the failure modes claimed.
      4. The task is genuinely single-module per CLAUDE.md "Risk-driven rigor bar" — if multi-module slipped through, recommend /swarm instead.
    Submit BLOCKED/APPROVED via Write to .forgeos/changesets/<branch>/architect-review.md
    (the changeset doesn't exist yet at this point — Phase 2 creates it).
```

Skip permitted ONLY in two cases:
1. The area has a current `docs/architecture/areas/<area>/verification-checklist.md` AND your fix-contract matches it 1:1 (delta-verified against the checklist).
2. Trivial 1-LOC fix in a critical path (still run /forge-review at the end per CLAUDE.md).

If the architect-reviewer returns BLOCKED, fix the contract, re-spawn, do not proceed to Phase 2 until APPROVED.

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

### Phase 3.5 — Class scan + detector codify (MANDATORY when a new bug-class is identified)

**Fire when** any of:
- (Phase 1 architect) recon surfaces a pattern that recurs at ≥2 call sites — even if only 1 is currently broken.
- (Phase 2 implementer) writing the fix, notices the same shape elsewhere in the diff hunks they touched.
- (Phase 3 skeptic) running `/clean-code` or the per-area verification-checklist greps, finds the same shape.
- (Phase 4 qa-reviewer) blocks with a finding that classifies as a *class*, not a single instance.
- (any phase) the human says "scan for this elsewhere."

**The 5-step loop:**

1. **Characterize** — write a 1-paragraph definition of the bug class. What is the call-pattern that, when present, indicates a defect? Be precise enough that someone else can grep for it.
2. **Scan** — use the right tier (see below). Output: a list of survivor sites with `file:line`.
3. **Triage** — for each survivor, classify: (a) trivial inline fix (apply now), (b) scope-deferral (queue with ticket and rationale), or (c) false positive (annotate with `// no-<wall-id>: <reason>`).
4. **Wipe** — apply (a) fixes in this PR. The PR fixes the class, not just the originally-reported instance.
5. **Codify detector** — add `scripts/check-<wall-id>.py` that catches future instances. **This is the load-bearing artifact**, not the one-time wipe. Wire it into `scripts/verify-pr.sh` (both `--quick` and full) and `.claude/settings.json` PreToolUse hooks. Add `scripts/test_check_<wall-id>.py` per the existing detector test convention.

**3-tier mechanism — pick the right one:**

- **Tier 1 — `grep` / `ripgrep`.** When the class is a single literal call-pattern with no semantic disambiguation needed. Cheap, ~1 second. Example: every site that calls `markCredentialsStale()` literally.
- **Tier 2 — Explore subagent.** When the class needs *reading* (semantic disambiguation: which `Timer.publish(every:)` calls should invalidate during backgrounding vs which shouldn't). Cost: ~10 minutes / one subagent invocation. Output: `file:line` list with brief rationale per finding.
- **Tier 3 — dedicated detector script at `scripts/check-<wall-id>.py`.** Runs in `scripts/verify-pr.sh` + pre-commit. **THIS IS THE PERMANENT WALL.** The one-time wipe catches *current* instances; the detector catches *future* ones. Without Tier 3 the class can recur next month.

**Discipline guardrails (NON-NEGOTIABLE):**

- **Scope-deferral protocol applies.** If the class scan returns >5 survivors and fixing all of them would push this PR past 600 LOC, STOP with the BLOCKED + scope-reduction proposal per CLAUDE.md. Do not silently ship "we fixed 3 of 8 sites and the PR title is `fix(<thing>)` while the issue remains in 5 sites." Tier 3 still lands in this PR — the detector catches the deferred sites at the next commit they touch.
- **Triage budget.** Small class (≤3 survivors, ≤50 LOC fix): instant fix, no follow-up ticket. Big class (>3 survivors or >50 LOC fix): scope-defer, file a Jira follow-up *and* land the detector. The detector + the deferred-follow-up ticket together IS the wall — neither alone is sufficient.
- **The detector script catches future instances; the wipe only catches current ones.** When the choice is "spend the budget on the wipe vs the detector," **prefer the detector**.

**Output of Phase 3.5 (committed at PR time):**
- `scripts/check-<wall-id>.py` + `scripts/test_check_<wall-id>.py`
- Wiring in `scripts/verify-pr.sh` (both `--quick` and full) — use the existing `run_m1_check` helper shape
- `.claude/settings.json` PreToolUse Bash hook entry (`scripts/hooks/pre-commit-<wall-id>.sh` if a wrapper is needed, otherwise inline)
- Wall-failure entry `.forgeos/wall-failures/YYYY-MM-DD-<short-id>.md` with `detector_script:` populated per the README + TEMPLATE convention
- Commit body reconciles "wiped N sites, detector covers future" via `check-contract-reconciliation.py`

See `docs/architecture/phase-3.5-class-scan.md` for the architecture-level rationale, the 6 detectors that landed via this swarm, and the cluster-vs-instance decision log.

### Phase 4 — /forge-review (architect + qa_test + blast_radius SoD)

```
/forge-review
```

Same SoD pattern as /swarm. Reviewer count is **3**: `architect`, `qa_test`, and `blast_radius` (universal floor). The blast_radius reviewer is mandatory regardless of gate template per swarm `swarm_M1_83be56fc` (2026-05-28) — closes the 11-finding gap waves 1-4 surfaced AFTER architect + qa_test review. If BLOCKED by any of the three:
1. Create a wall-failure entry per `.forgeos/wall-failures/README.md`. Per Phase 3.5, the entry MUST land with a `detector_script:` (or a `no-detector:` justification) — the wall is the detector, not the one-time wipe.
2. Fix the finding (apply Phase 3.5 if the block classifies as a *class*, not a single instance).
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
