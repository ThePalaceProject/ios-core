---
name: wall-failures-readme
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-06-05
freshness_window: 365d
owners: [general]
description: Wall-failure catalog
---

# Wall-failure catalog

**Purpose:** every reviewer-blocked finding is a system bug, not just an implementer bug. This catalog records what escaped, which wall should have caught it, and what permanent improvement closes the gap so the next swarm can't repeat it.

## The thesis

A trust-boundary system is valuable when someone cuts a corner and the system catches it anyway. PR #1018 (swarm_66819d80) had both SoD reviewers BLOCK with real findings — a fake migration in `TPPNetworkResponder` plus two test files that never instantiated the services they claimed to verify. All 4 prior gates (TDD, mutation, verify-pr.sh, architect contract) passed.

The right response to a reviewer block is **not** "fix the finding and move on." The right response is:

1. Fix the finding.
2. Ask: *what contract clause, orchestrator check, or implementer constraint would have made this finding impossible to land?*
3. Add it.

Each blocked finding becomes a permanent system improvement. After ~5-10 swarms, the system has learned which classes of corner-cut to prevent. The reviewer round-trip rate drops. Implementer dishonesty stops being absorbable.

## Structure

```
.forgeos/wall-failures/
├── README.md                  (this file)
├── TEMPLATE.md                (copy this for new entries)
├── INDEX.md                   (one-line summary per entry, sortable by category)
├── 2026-05-27-pr1018-arch1.md (one file per finding)
├── 2026-05-27-pr1018-arch2.md
├── ...
└── derived-improvements.md    (running tally of what's been codified)
```

## Workflow

### When a reviewer BLOCKS (or a bug ships, or a near-miss is observed)

1. **Inside 24h:** create a wall-failure entry using `TEMPLATE.md`. Name: `YYYY-MM-DD-<pr>-<short-id>.md`.
2. **Same session:** classify which "wall" should have caught it (see categories below).
3. **Same session:** propose a permanent fix — a contract clause, orchestrator check, implementer constraint, hook, gate, or test pattern that would have prevented it.
4. **Same session:** submit the lesson to the ForgeOS ADR ledger so it's discoverable via `forge_list_adrs` + reviewer agents, not just by grep:
   ```bash
   python3 scripts/forgeos-submit-wall-failure.py .forgeos/wall-failures/<entry>.md
   # optional: --area <topic-specific area> if the failure is auth/audiobooks/etc.,
   #          --changeset <cs_xxxxxxxx> if you have an active changeset to attach to
   ```
   The script writes `adr_ref: adr_<8hex>` back into the entry's frontmatter and is idempotent on re-run. Without this step, the wall-failure stays write-only — future reviewers and `intent` skill can't discover it.
5. **Within 1 week:** apply the proposed fix (skill update, CLAUDE.md edit, hook change, etc.) and link the commit/PR back from the entry.
6. **Add a line to `INDEX.md`** so the catalog stays navigable.

### Detector requirement (2026-06-05, swarm_162a3219)

Every wall-failure entry MUST have either:

- `detector_script: scripts/check-<wall-id>.py` in frontmatter AND a `## Detector script` section in the body describing the catch-pattern + linking to `scripts/test_check_<wall-id>.py`, OR
- `no-detector: <reason>` in frontmatter — only acceptable when the class is semantic-only and a static script genuinely cannot encode it (e.g., "behavior depends on runtime state in a 3rd-party library"). The reason must be specific; "too hard" is not acceptable.

The entry's `detector_status:` is one of:

- `built` — script + tests landed in the same PR as the wall-failure entry
- `queued` — entry exists, detector pending in a named follow-up PR (record the PR number)
- `no-detector` — justification recorded in frontmatter and body

A wall-failure entry without one of these is `wall_status: open` regardless of whether the one-time fix landed. **The detector is the wall — the wipe is just the incident response.** See `/rigorous-fix` Phase 3.5 (`.claude/skills/rigorous-fix/SKILL.md`) for the 5-step loop + 3-tier mechanism + discipline guardrails that produce the detector.

This convention applies forward (every new entry must comply); backfill of existing entries is a separate pass tracked in `derived-improvements.md`.

Schema example for an entry's frontmatter:

```yaml
---
date: 2026-06-05
pr: "#1044"
walls: [reviewer, contract]
severity: high
wall_status: applied
detector_script: scripts/check-foreign-host-401-scoping.py
detector_status: built
...
---
```

Or, when no static detector is feasible:

```yaml
detector_script: ""
no-detector: "Class is semantic — depends on 3rd-party AVPlayer runtime callback timing; no AST/grep pattern can encode the failure shape."
detector_status: no-detector
```

### Once per month (or every ~10 entries)

1. Read `INDEX.md` end-to-end.
2. Identify clusters — *"60% of escapes are missing simdrive coverage on Reader2"* or *"40% are fake-test-instantiation"*.
3. Promote cluster-level fixes (new skill, new contract template, new hook) over individual entry-level fixes.
4. Update `derived-improvements.md` with the cluster + the fix.

## Wall categories

When classifying, pick the *innermost* wall that should have caught it:

| Wall | What it does | Examples |
|---|---|---|
| **contract** | Architect's per-module spec at swarm start | "Test must instantiate the SUT" missing from acceptance criteria |
| **implementer** | Self-checks inside the implementer's pass | Implementer's self-grep should have caught dead-call-site |
| **TDD** | Failing test → minimal prod code | Test was written but never asserted on the actual SUT |
| **mutation** | Mutating production catches non-asserting tests | Mutation skipped or didn't cover the changed lines |
| **verify-pr** | Pre-PR battery — build, lint, coverage, a11y, simdrive | Missing simdrive recording for the IdP × scenario |
| **orchestrator** | Integration pass between implementer return and review | Orchestrator trusted the transcript without verifying claims |
| **reviewer** | SoD architect or qa_test agent | Reviewer prompt didn't ask the right question |
| **hook** | Pre-commit / pre-push enforcement | Hook didn't catch missing scope stanza for the change class |
| **stale-doc** | Out-of-date documentation contributed to the failure | Engineer followed an area checklist that hadn't been refreshed in 11 months; the documented invariant had been broken by an intervening change without checklist update |

## Why this works

Most teams retro a bug as a one-off — *"we fixed the timing issue."* The class of failure is the load-bearing insight. If every escape gets a structured entry tagging *(which wall, why it leaked, what would have caught it)*, after 20-30 entries you'll see patterns. *"68% of escapes are missing simdrive coverage on Reader2"* is actionable infrastructure investment, not vibes.

The same logic applies to **near-misses** that didn't escape because a reviewer caught them. A reviewer-blocked finding IS a wall failure — the only thing that saved you was the reviewer, which means every wall *before* the reviewer is leaking. Don't wait for shipped bugs to populate the catalog; the BLOCKED verdicts are the highest-density source.

## Related

- Demo doc `03-improvements-roadmap.md` Tier 3 #7 (wall-failure catalog) is the philosophical parent.
- This catalog is the operational version.
- Connects to the harness's existing ledger and forge-review infrastructure — entries should reference review IDs (`rev_*`) and changeset IDs (`cs_*`) where applicable.
