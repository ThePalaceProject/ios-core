---
date: YYYY-MM-DD
pr: "#NNNN"
source: reviewer-block | shipped-bug | near-miss | retro-observation
reviewer_ids: [rev_xxxxxxxx]
changeset_id: cs_xxxxxxxx
wall: contract | implementer | TDD | mutation | verify-pr | orchestrator | reviewer | hook
walls: []  # array form, preferred for new entries; multiple walls can contribute.
           # Values: contract | implementer | TDD | mutation | verify-pr | orchestrator | reviewer | hook | stale-doc
           # Legacy single-value `wall:` above stays for backward compatibility.
severity: low | medium | high | critical
wall_status: open | proposed | applied
applied_in: ""  # commit SHA or PR # where the permanent fix landed
contributing_docs:  # optional; populate when a stale doc contributed to the failure.
                    # Each entry: {path, last_refresh_at_failure, decay_days}
                    # decay_days = (failure_date - last_refresh_at_failure)
  # - path: docs/architecture/areas/<area>/verification-checklist.md
  #   last_refresh_at_failure: YYYY-MM-DD
  #   decay_days: 0
# doc-lifecycle metadata (added by Module B sweep)
name: wall-failures-template
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: Title — one-line summary of what escaped
---

# Title — one-line summary of what escaped

## Finding (verbatim from reviewer / bug report)

Paste the exact verdict text, including the file:line citation.

## What actually happened

Plain-English explanation: what did the implementer do, why did it look correct on the surface, what was actually wrong underneath.

## Walls that should have caught it (and why they didn't)

For each wall:
- **<wall>**: why it didn't catch it. Be specific. "Mutation didn't catch it because mutation was skipped on this file" or "Contract didn't catch it because the acceptance criteria said 'test the migration' without specifying 'test must instantiate the SUT'."

## Proposed permanent fix

Concrete and grep-able. *Not* "be more careful next time." Examples:
- Add to swarm SKILL.md contract template: *"Every test file must contain `grep -c "<SUT>(" <test-file>" ≥ 1`."*
- Add to CLAUDE.md Definition of Done: *"For every new function call in production code, paste evidence that the result is used or document the discard with a TODO."*
- Add pre-commit hook: *"Block commits that add `_ = newFn()` without an inline `// rationale: ...` comment."*

The fix should make the finding **structurally impossible to land**, not "more likely to be noticed."

## Stale-doc contribution

Fill this section only when `stale-doc` is in `walls:`. For each contributing doc:

- **Doc path:** `docs/architecture/areas/<area>/verification-checklist.md`
- **Last refresh before failure:** YYYY-MM-DD (commit SHA optional)
- **Decay at failure:** N days (= failure_date − last_refresh)
- **What the doc said vs. reality:** plain-English diff — the invariant the doc asserted and the intervening change that broke it without a checklist update.
- **Freshness-window implication:** does this doc's category need a tighter refresh cadence? Link the proposed cadence change.

If `stale-doc` is NOT in `walls:`, delete this section.

## Application log

- YYYY-MM-DD — fix applied in `<commit-or-PR-link>`
- YYYY-MM-DD — observed in subsequent swarm `swarm_xxxxxxxx`: this class of finding did/did-not recur

## Related entries

Link to other wall-failure entries that share root cause, wall, or proposed fix. Clusters here are the input to the monthly review pass.
