<!-- audit-verified: A4 from .forgeos/wall-failures/derived-improvements.md — this schema enforces architect post-review per PR #1018 architect under-estimating test surface 7x. -->

# Swarm manifest schema v2 — architect post-review enforcement

## What changed from v1

v1 manifests had no required architect-review field. The swarm SKILL.md described Phase 1a (architect post-review) but it was advisory — implementers could proceed without it. v2 adds a REQUIRED `architect_review` field that Phase 4.5 verifies BEFORE allowing dispatch verification.

## Why

PR #1018's architect Phase 0 recon estimated 48 tests in the auth area; reality was 385+. A 7× miss in a load-bearing input. The implementers built contracts off the under-scoped recon. If a second architect-reviewer had verified the recon before dispatch, the estimate gap would have surfaced before propagating to all 4 implementer contracts.

## Schema additions (required from v2 onward)

```yaml
swarm_id: swarm_<8hex>
# ... v1 fields unchanged ...

# v2 ADDITIONS — REQUIRED:
architect_review:
  reviewer_agent_id: <agent id from Agent tool return>
  verdict: APPROVED | BLOCKED
  at: <ISO timestamp>
  reviewed_files:
    - .forgeos/swarms/<swarm_id>/plan.md
    - .forgeos/swarms/<swarm_id>/contracts/*.md
    - <recon doc paths from manifest.recon_docs>
  findings: |
    Free-text. Required if verdict == BLOCKED, optional if APPROVED.
    For APPROVED with caveats, list them here.
  skipped:
    reason: <enum: area_checklist_authoritative | trivial_scope | <other>>
    justification: <free text — required if skipped.reason is set>
```

## Phase 4.5 enforcement (added to swarm SKILL.md skeptic pass)

```bash
# Existing Phase 4.5 checks 1-6 ...

# Check 7: architect_review block populated and APPROVED
ARCH_REVIEW=$(yq -r '.architect_review.verdict' .forgeos/swarms/$SWARM_ID/manifest.yaml 2>/dev/null)
ARCH_SKIPPED=$(yq -r '.architect_review.skipped.reason' .forgeos/swarms/$SWARM_ID/manifest.yaml 2>/dev/null)

if [ "$ARCH_REVIEW" = "BLOCKED" ]; then
  echo "BLOCK: architect_review.verdict == BLOCKED. Address findings and re-run."
  exit 1
fi

if [ "$ARCH_REVIEW" = "APPROVED" ]; then
  echo "[skeptic-pass] architect_review present and APPROVED"
elif [ "$ARCH_SKIPPED" != "null" ] && [ -n "$ARCH_SKIPPED" ]; then
  echo "[skeptic-pass] architect_review skipped: $ARCH_SKIPPED (justified)"
else
  echo "BLOCK: architect_review missing or no verdict. Per swarm SKILL.md Phase 1a, run architect-reviewer subagent before dispatching implementers."
  exit 1
fi
```

## Skip clause

A swarm may skip architect post-review if:
1. The touched area has a current `docs/architecture/areas/<area>/verification-checklist.md` AND
2. The architect's recon contains the phrase "delta-verified against `<checklist-path>`" with cited diffs from the checklist's prior refresh

In that case, set `architect_review.skipped.reason: area_checklist_authoritative` and `architect_review.skipped.justification: "<checklist-path> last refreshed <date>; architect delta-verified against it; full re-review would be redundant."`

This carve-out preserves the discipline (someone verified) while avoiding redundant work when the prior architect-or-area-maintainer already did the heavy lifting.

## Migration

v1 manifests (existing swarms) are grandfathered — Phase 4.5 only enforces v2 schema on swarms with `swarm_id` >= `swarm_66819d80` (the first PR-#1018-class swarm where this discipline applies retroactively per the lessons captured).

Practically: any new swarm started after this schema lands MUST be v2. Old in-flight swarms can opt in voluntarily.

## Related

- Swarm SKILL.md Phase 1a (architect post-review) — describes the agent dispatch
- Swarm SKILL.md Phase 4.5 (orchestrator skeptic pass) — describes the enforcement
- `.forgeos/wall-failures/derived-improvements.md` — A4 entry tracks this work
- B3 backtest report — finding #1 (mandatory SharedMind queries for high-risk modules) suggests architect-reviewer prompts should mandate `forge_query_mind` calls for the swarm's domain BEFORE approving the recon
