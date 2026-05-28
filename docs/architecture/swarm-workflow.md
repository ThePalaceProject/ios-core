---
name: swarm-workflow
type: evolving
status: active
created: 2026-05-11
last_refresh: 2026-05-11
freshness_window: 365d
owners: [general]
description: "/swarm — multi-module orchestration loop"
---

# /swarm — multi-module orchestration loop

This doc captures the **why** for the `/swarm` skill that lives at
`.claude/skills/swarm/SKILL.md`. The skill is the operational surface; this
doc is the architectural rationale, who-reads-what, and the decision log.

## What it solves

Palace has clean module seams (Catalog, Audiobooks, Reader2, SignInLogic,
MyBooks, Settings, …) but **multi-module changes are still serialized through
one agent transcript**. A single agent doing an SPM extraction or a
cross-module refactor:

- Pays a context-load cost on every module it visits (re-reading conventions,
  re-orienting in the directory).
- Holds all the work in one growing transcript, eating context budget.
- Has no machine-readable artifact for "which module owns which change."

`/swarm` doesn't add new infrastructure — every piece existed already
(ForgeOS gates, `forge-review` reviewer subagents, hooks enforcement,
`verify-pr.sh`, `pbxproj_add_swift.rb`, `export-module-contracts.py`). It
**wires those pieces into a triage→dispatch→integrate→promote loop** so
multi-module work parallelizes cleanly.

## What it is not

- **Not a CI tool.** `/swarm` runs in your local Claude Code session, not
  GitHub Actions.
- **Not a replacement for single-agent work.** Single-module changes,
  bugfixes <50 LOC, docs edits — all of those should remain single-agent.
  Triage overhead exceeds parallelism gain on small work.
- **Not a planning tool.** The architect agent inside `/swarm` does *triage*
  (which module gets which contract), not roadmap planning.

## The loop

```
user task
   │
   ▼
┌──────────────────────────────────────────────────┐
│ 1. Triage (architect agent, single subagent)     │
│    - reads .forgeos/contracts/*.json             │
│    - identifies touched modules                  │
│    - writes per-module contract delta            │
│    - writes manifest.yaml + plan.md              │
└──────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────┐
│ 2. ForgeOS changeset                              │
│    - mcp__forgeos__forge_propose_changeset       │
│    - referenced from commit message later        │
└──────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────┐
│ 3. Dispatch (N implementer agents in parallel)   │
│    - each reads its contract.md                  │
│    - each modifies only its scoped files         │
│    - each uses scripts/pbxproj_add_swift.rb      │
│    - each writes transcripts/<module>.md         │
└──────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────┐
│ 4. Integrate (main agent / you)                  │
│    - read transcripts, resolve "gaps" flags      │
│    - run verify-pr.sh --quick                    │
│    - run export-module-contracts.py --check      │
│    - fix small regressions inline                │
└──────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────┐
│ 5. forge-review                                  │
│    - existing skill spawns architect + qa_test   │
│    - resolve any rejections                      │
└──────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────┐
│ 6. Promote, commit, open PR                      │
│    - mcp__forgeos__forge_promote_gate per gate   │
│    - commit (pre-commit hook validates stanzas)  │
│    - gh pr create                                │
└──────────────────────────────────────────────────┘
```

## Artifacts (the audit trail)

Every swarm writes to `.forgeos/swarms/<swarm_id>/`:

```
.forgeos/swarms/swarm_a1b2c3d4/
├── manifest.yaml      ← machine-readable; agents parse this
├── plan.md            ← human-readable; you read this
├── contracts/<M>.md   ← per-module scope + invariants
├── transcripts/<M>.md ← per-implementer summary
└── outcome.md         ← final integration report
```

These are **committed**, not gitignored. They are the audit trail for the
ForgeOS changeset — they let a reviewer or auditor trace "this multi-module
PR was driven by N agents under contract X, each scoped to file set Y."

## Decision log

### Why an architect *agent* and not a hand-written plan?

Because the architect must read the same `.forgeos/contracts/*.json` that
implementers consume. Hand-written plans drift from the contract export
format; the architect agent's output stays aligned because it's fed the same
inputs every other piece of the system uses.

When the user already has a plan, `/swarm` skips Phase 1 — feed the plan
directly into manifest.yaml, dispatch, integrate. The architect is for
"figure out what to do," not "validate what I told you to do."

### Why parallel implementers and not parallel architects?

Architecture is a global view; implementation is a local view. Splitting the
architect into parallel architects re-introduces the contract-coupling
problem `/swarm` exists to avoid. Splitting implementers does the opposite —
each implementer has a focused contract and minimal context-load cost.

### Why ForgeOS changeset before dispatch, not after?

So implementer transcripts can reference the changeset ID as evidence. Without
the changeset existing, evidence-submission becomes a post-hoc paper exercise
instead of a real provenance link. Cost: one extra MCP call up front.

### Why is the integrator (main agent) responsible for cross-module wiring?

Integrator has the global view of all transcripts. Implementer agents are
contract-scoped and don't know what their siblings produced — they shouldn't.
Cross-module wiring (AppContainer composition, callsite updates that span
boundaries) belongs at the boundary, not inside any one contract. If an
implementer's transcript flags `gaps:`, that's a triage failure to capture
upstream OR a coupling that emerged during work — either way, the
integrator handles it.

### Why critical-path mutation enforcement now, but not full enforcement?

`verify-pr.sh --enforce-mutations` and the path regex
(`Audiobooks|SignInLogic|MyBooks/Download`) target the user-money/access
paths memory flagged. Full enforcement across the whole codebase would fail
PRs that touch UI code where mutation-killing is genuinely harder (e.g. layout
glue with no testable branch). We'd rather have honest enforcement on critical
paths than aspirational enforcement everywhere.

## Who reads what

### When a *human* is reading this swarm output

- Start with `plan.md` — a few hundred words, scannable.
- Look at `outcome.md` — what shipped, what was deferred, what was learned.
- Skim `transcripts/*.md` only if a reviewer asks "why did module X change
  this way."
- `manifest.yaml` is rarely useful to humans — it's machine-readable
  metadata.

### When an *agent* is reading this swarm output

- Start with `manifest.yaml` — modules list, contract paths, status.
- Read `contracts/<M>.md` for the module the agent is implementing.
- Cross-reference `transcripts/*.md` from sibling implementers if needed
  (rare; integrator handles cross-module).

## Failure-mode reference

The skill body documents recovery for each failure mode. The summary view:

| Symptom | Likely cause | Recovery |
|---|---|---|
| Implementer reports out-of-scope edit | Architect missed coupling | Integrator handles cross-module change |
| Two contracts touch same files | Architect overlapped scopes | Merge contracts, re-dispatch one implementer |
| One implementer fails | Scope-specific issue (compile, test) | Re-spawn just that one with failure log |
| `verify-pr.sh` fails after integration | Small: fix inline. Big: re-spawn module. |
| Reviewer rejects gate | Read rejection. Architectural? back to triage. Cosmetic? fix inline. |

## Examples

### Good: SPM extraction (PalaceAuth from SignInLogic)

- 22 Swift files, pure Swift, multiple natural seams
- 3-4 implementers can run truly parallel: package skeleton, public API,
  callsite migration, test migration
- Contracts are small and overlap-free (architect can write them in 10
  minutes of agent time)

### Good: Cross-module feature flag system

- New `FeatureFlags` infrastructure in Settings
- Audiobooks + Reader2 each consume a flag
- Settings owns the flag-publication contract; consumers each get a small
  contract for "subscribe + branch on flag"

### Bad: Singleton sweep across 40 files

- File-level changes, not module-level
- The unit of work is a `.shared` reference replacement, repeated; not
  a contract that benefits from architect triage
- Better as a single-agent campaign with a checklist, or a script

### Bad: One-line bugfix in 3 files

- Triage overhead > work
- Use single-agent

## Related infrastructure

- [`scripts/pbxproj_add_swift.rb`](../../scripts/pbxproj_add_swift.rb) — used
  by implementers to add Swift files to `Palace.xcodeproj`.
- [`scripts/export-module-contracts.py`](../../scripts/export-module-contracts.py) —
  generates `.forgeos/contracts/<module>.json` for the architect to read.
- [`scripts/palace_mutate.py`](../../scripts/palace_mutate.py) — caches
  mutation results in `.forgeos/mutation-cache/`; integrator uses this via
  `verify-pr.sh`.
- [`PalaceTests/RegressionGuards/`](../../PalaceTests/RegressionGuards/) —
  per-crash-family regression guards integrated into the verify-pr battery.
- [`forge-review`](../../.claude/skills/forge-review/) — existing skill that
  spawns SoD reviewers; called by `/swarm` Phase 5.
