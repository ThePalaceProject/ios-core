---
name: critical-path-review-policy
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: Critical-path review policy
---

<!-- audit-verified: B5 from .forgeos/wall-failures/derived-improvements.md — policy implementation lives at ~/harness/core/hooks/pre-push-critical-path-review.sh; registered in .claude/settings.json. Hook code reviewed and verified at time of writing. -->

# Critical-path review policy

**Status:** Active as of 2026-05-28 (PR #1019).
**Enforcement:** `pre-push-critical-path-review.sh` hook + `.claude/settings.json` PreToolUse Bash registration.

## The rule

Any push that touches a **critical-path** file requires evidence of architect + qa_test review in the pushed commits. The hook BLOCKS the push if fewer than 2 review references are found.

The 50-LOC "swarm only when ≥2 modules" bar from the swarm SKILL.md is *structural*. This policy is *risk-driven*. They're different and both apply.

## Critical paths

Per CLAUDE.md "Risk-driven rigor bar":

- `Palace/SignInLogic/` — auth, sign-in
- `Palace/Packages/PalaceAuth/` — auth substrate
- `Palace/MyBooks/Borrow*` — borrow flow
- `Palace/MyBooks/BookReturn*` — return flow
- `Palace/MyBooks/Download*` — download + DRM fulfillment
- `Palace/Audiobooks/` — audiobook playback (toolkit fragile)
- `Palace/Migrations/` — persistence schema
- `Palace/Network/TPPNetworkResponder.swift`, `Palace/Network/TPPNetworkExecutor.swift` — auth-error decision points

If a regression in any of these would hit users, the review must happen — regardless of LOC count, regardless of how the code was authored.

## How to satisfy it

Pick the right tool for the work:

| Scope | Tool | What runs |
|-------|------|-----------|
| Multi-module critical-path change | `/swarm` | Architect → contracts → parallel implementers → /forge-review (architect + qa_test) |
| Single-module critical-path change | `/rigorous-fix` | Architect-light recon → fix-contract → /forge-review (architect + qa_test) |
| Single-file critical-path change (after coding) | `/forge-review` directly | Architect + qa_test review |
| Non-critical-path change | `/clean-code` (skeptic-pass greps J1-J5) | Single-agent self-check |

After `/forge-review` approves, the verdict IDs (`rev_<8hex>`) appear in the changeset and should be referenced in your commit body. The hook scans for those refs in `git log <upstream>..HEAD`.

## What the hook checks

1. Push happening on a branch with critical-path file changes (vs `origin/<branch>` or `origin/develop`)?
2. Commits between upstream and HEAD contain ≥2 of:
   - `rev_<8hex>` ID (architect or qa_test verdict)
   - `outcome.md` reference (swarm completed)
   - explicit "forge-review verdict: APPROVED" text

If yes to (1) and no to (2): BLOCK with instructions.

## Bypass

`SKIP_CRITICAL_PATH_REVIEW=1 git push ...`

Use only for genuine emergencies. The bypass leaves a paper trail (the env var doesn't propagate to commit messages, but the lack of review IDs is visible in the audit). If you bypass more than once per release cycle, the policy is wrong for your team's actual workflow — surface to the harness owner.

## What this does NOT do

- Does NOT verify the review verdicts are actually APPROVED (just that they're referenced). The reviewer agent's submission of APPROVED is verified separately in ForgeOS; this hook just enforces "you ran the reviewer."
- Does NOT require the reviewer to be a different agent / role than the author. SoD is enforced by ForgeOS gates + /forge-review's role-spawning, not by this hook.
- Does NOT check non-pushed local commits. Only pushed range.

## History

- 2026-05-28 — landed in PR #1019 chore/swarm-rigor-meta-improvement. Motivated by:
  - PR #1018's reviewer-block-and-fix loop demonstrating real value of SoD review
  - The structural 50-LOC bar being wrong for critical-path single-module work
  - B3 backtest showing 0% definitive catch of prior shipped bugs by reviewer agents — *the floor* needs to be that reviewers run AT ALL on critical paths
