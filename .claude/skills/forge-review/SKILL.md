---
name: forge-review
description: Run the SoD-required reviewers against the current ForgeOS changeset. Detects which gates are pending and require role-based reviews (architect, qa_test, blast_radius, etc.), spawns the matching subagent for each, and reports verdicts. Use when a PR is ready for review under harness governance and the author cannot self-approve. Invoke via "/forge-review" or when the user says "review my PR", "run the forge reviewers", "get architect/QA review on this changeset", or asks how to satisfy a blocked SoD gate.
tools: Bash, Read, Agent, mcp__forgeos__forge_check_gates, mcp__forgeos__forge_promote_gate, mcp__forgeos__forge_release_check
---

# /forge-review — orchestrate ForgeOS SoD reviewers

You provide one-command review-orchestration for ForgeOS gates that have role-based requirements (architect, qa_test, blast_radius, security, etc.) which the changeset's author cannot satisfy themselves under SoD policy. This is the typical solo-dev case under harness governance.

## When invoked

The user is asking you to run the reviewers for the current changeset. You have to determine WHICH changeset and WHICH reviewers.

## Inputs (gather these first)

1. **Project ID and changeset ID.** Try, in order:
   - User-provided in the prompt (e.g. "review cs_50b36897")
   - From the current branch's ForgeOS state — find a `cs_*` referenced in recent commit messages on this branch (`git log --all --grep "ForgeOS changeset:" -10 --pretty=%B | grep -oE "cs_[a-f0-9]+" | head -1`)
   - From the harness project YAML — `eval "$(python3 ~/harness/core/lib/load-project-config.py)"` to get `FORGEOS_PROJECT_ID`
   - If still ambiguous, ask the user

2. **Worktree path.** Resolve the worktree containing the in-flight branch. If the user is in a worktree, use PWD. Otherwise check `git worktree list` for matches.

3. **Base ref.** Default `origin/develop` unless the user specifies otherwise.

## Process

### 0. Universal floor — always include blast_radius

Regardless of what gates the changeset declares as required, **always spawn `forge-blast-radius-reviewer`** as the universal floor reviewer. Waves 1-4 surfaced 11 findings AFTER architect + qa_test review — the blast-radius lens closes that class of gap (test-only public counters, `#if DEBUG` production reachability, contract-vs-diff drift, test-seam bypass). Treat blast_radius as **mandatory for every PR** even if the gate template doesn't list it; submit the review with `role=blast_radius` and let ForgeOS record it as an advisory if the gate doesn't require it formally. If a gate DOES require `blast_radius`, the same review covers it — no double-run.

This universal floor was added 2026-05-28 as the swarm `swarm_M1_83be56fc` outcome. It runs in parallel with the per-gate reviewers identified in Step 2 below.

### 1. Read gate state

Call `mcp__forgeos__forge_check_gates` with `(project_id, changeset_id)`. The response lists each gate with status, required evidence, required roles, completed roles.

### 2. Identify reviewers needed

For each gate where `status == "pending"` AND `required_roles` is non-empty AND `completed_roles` doesn't yet include those roles, that gate needs a reviewer. Map roles to reviewer subagents:

| Required role | Subagent (subagent_type) |
|---|---|
| `architect` | `forge-architect-reviewer` |
| `qa_test` | `forge-qa-reviewer` |
| `blast_radius` | `forge-blast-radius-reviewer` |
| `security` | `forge-security-reviewer` (if defined; else fall back to `general-purpose` with the architect spec adapted for security focus) |
| `accessibility` | `forge-a11y-reviewer` (if defined; else fallback) |
| `performance`, `reliability`, `docs_release` | fall back to `general-purpose` with role-specific prompt |

If a needed reviewer subagent doesn't exist yet, use `general-purpose` and tell it to read `~/harness/integrations/claude-code-skill/agents/forge-architect-reviewer.md` for the review-shape spec, then specialize for the missing role.

When you spawn `forge-architect-reviewer` (or a fallback acting in the architect role), instruct it to consult `.forgeos/reviewer-refs/architect-swift-canon.md` as a **lens, not a checklist** for any structural change (new abstractions, type-hierarchy changes, protocol surfaces, concurrency model shifts) — and to weigh `.forgeos/wall-failures/` over the canon when they disagree.

**ADR-aware reviewer brief (added 2026-06-03 with v3 ADR ledger).** Tell every spawned reviewer (architect + qa_test + blast_radius + fallbacks) that they MUST call `forge_list_adrs(project_id, area=<each touched module>)` and `forge_get_context(project_id, changeset_id)` before writing a verdict. ADR contradictions without explicit `metadata.supersedes` submission are a `discipline` finding at minimum `concern`. If the changeset has no `modules_affected` populated, that's itself a finding — the reviewer brief is impoverished without it. Module list can be inferred via `python3 scripts/forgeos-modules-from-diff.py <base_ref> --format lines` (Palace iOS) or hand-derived from the diff path prefixes.

Per Step 0, **always add `forge-blast-radius-reviewer` to the list of reviewers to spawn** even if no gate explicitly required `blast_radius` — submit the review as advisory and treat any BLOCKED verdict as an issue the author must address before promoting, identical to a gate-required reviewer.

### 3. Spawn reviewers (in parallel where possible)

For each required reviewer (and the universal blast_radius floor), invoke `Agent` with:
- `subagent_type` matching the role (or `general-purpose` fallback)
- `description` short, e.g. "Architect review of cs_50b36897"
- `prompt` with the standard inputs:
  ```
  project_id: <pid>
  changeset_id: <cs>
  branch: <branch>
  worktree_path: <path>
  base_ref: <base>
  ```
  Plus context the user gave you (what changed, prior reviews if any).

If multiple reviewers are independent (no shared state), spawn them in parallel by sending all `Agent` calls in a single message. If sequential matters (rare), invoke serially.

### 4. Collect verdicts

Each reviewer returns a verdict (approved / blocked / pending). Capture them.

### 5. Promote passed gates

For each gate whose required roles are now all complete (architect approved → review gate; qa_test approved → testing gate), call `mcp__forgeos__forge_promote_gate`. Only promote gates where:
- All required roles have approved
- All required evidence is provided

If any gate's required role was BLOCKED by its reviewer, do NOT promote — surface the findings to the user instead. The same applies to the universal blast_radius reviewer: if BLOCKED, do not promote ANY gate even if blast_radius wasn't formally required — the finding represents a wave-1-4-class regression and the author must address it.

### 6. Release-check (if all gates passed)

If every gate is now `passed`, call `mcp__forgeos__forge_release_check`. Report the final state — `can_release: true` means the changeset can be pushed and PR'd. `can_release: false` lists what's still blocking.

### 7. Report to user

Summarize ≤ 250 words:
- Reviewers run + verdict each
- Gates promoted vs gates blocked
- Final release status (can_release y/n)
- For any blocked gate, the reviewer's top findings + what to fix
- Next concrete action (fix issues, push & open PR, etc.)

## Caveats / honesty

- **Don't override blocked verdicts.** If a reviewer blocks, that finding has to be addressed by the author. You don't "appeal" to the reviewer or rephrase the prompt to get approval — that defeats the SoD purpose.
- **Don't call reviewers on changesets that don't need them.** If a gate is already `passed` or doesn't have role requirements, skip — EXCEPT the universal blast_radius reviewer, which runs on every PR per Step 0.
- **Don't promote gates without the role completions.** Even if you ran a reviewer, only promote when the role is officially `completed_roles`.
- **Don't push or open PRs.** That's a separate step the user takes after release-check passes.

## Example session shape

User: `/forge-review`

You:
1. Detect: branch `chore/coverage-by-fr-check`, changeset `cs_50b36897`, project `proj_87884c17`, worktree `~/PalaceProject/ios-core/.claude/worktrees/coverage-by-fr-check`.
2. `forge_check_gates` shows: `review` pending (architect), `testing` pending (qa_test), `release` pending (no role).
3. Spawn `forge-architect-reviewer`, `forge-qa-reviewer`, and `forge-blast-radius-reviewer` (universal floor) in parallel.
4. Architect: approved. QA: approved (with one warning about JSON parse-error opacity). Blast-radius: approved.
5. Promote `review`. Promote `testing`. Promote `release` (no role/evidence required).
6. `forge_release_check` → `can_release: true`.
7. Report: "All three reviewers approved (architect + qa_test + blast_radius universal floor). 3 gates promoted. Ready to push + open PR. Optional follow-up: address the QA warning about parse-error fail-mode opacity."

## Anti-pattern

User: `/forge-review` on a changeset they just opened, which has architecture issues.
Reviewer blocks with severity `concern`.
You then re-spawn the reviewer with a longer prompt explaining away the concern.

That's gaming the system. Do NOT do this. The author's job is to fix the issue and re-request review by re-running `/forge-review` after the fix is committed.
