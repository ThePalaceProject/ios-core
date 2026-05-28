<!-- audit-verified: C2 stub from .forgeos/wall-failures/derived-improvements.md — design + minimal scaffolding. Full implementation depends on Crashlytics MCP + HelpSpot MCP integration with files-about-to-be-edited inference. -->

# Session-observability → session-start context (C2 stub)

**Status:** STUB / DESIGN. Scaffolding landed in PR #1019; full implementation deferred to a follow-up sprint.

## Goal

When an agent starts a session and the SessionStart hook fires, surface production-observability signals relevant to files the agent is about to touch:

- Crashlytics issues opened on those files in the last 30 days
- HelpSpot tickets referencing those files / their behavior
- Wall-failure entries applicable to those files' area
- Recent reviewer-block patterns in those files' module

The agent then orients toward fixing what shipped wrong, not just what's queued.

## Why this matters

Today the SessionStart hook surfaces project state, sim pool, memory freshness, ForgeOS gate state. It does NOT surface production outcomes. So when a recent change lit up Crashlytics, the next session starts blind to it — unless the user remembers to surface it.

The DNA vision (`derived-improvements.md` + ForgeOS feedback file) calls for the codebase to inherit production signal automatically. C2 is the SessionStart-hook side of that.

## Why this is a stub, not a full implementation

The full implementation requires:
1. **Files-about-to-be-edited inference.** Hard at SessionStart — the agent hasn't yet declared intent. Heuristics: recent commits on this branch, current working changes, files in active swarm contracts, files referenced in MEMORY.md entries marked "Read first."
2. **Crashlytics MCP integration that filters by file/line.** Today Crashlytics MCP returns issues; mapping issue → source file requires the symbolicated stack trace + project source layout. Possible but not trivial.
3. **HelpSpot MCP integration that filters by area.** Today HelpSpot MCP returns tickets; mapping ticket → area requires NLP or curated taxonomy.
4. **Volume management.** A file like `TPPNetworkResponder.swift` could have hundreds of historical Crashlytics issues. Need ranking (recency × severity × open-status × user-impact) + a cardinality cap (top 5? top 10?).

Items 2-4 are infrastructure work. Item 1 is the load-bearing design question.

## Minimal scaffolding (this PR)

A documented hook signature + insertion point in the SessionStart hook chain:

```bash
# In ~/harness/core/hooks/session-start.sh, after existing state-loading:

# C2 stub — production observability context (placeholder)
# Once C2 is implemented, replace this comment with:
#   bash ~/harness/core/hooks/session-observability-context.sh
# The hook will print a structured block like:
#   ## Production signal for likely-touched files (last 30d)
#   - TPPNetworkResponder.swift: 3 Crashlytics issues (issue_8a3f, _b2e1, _c0d4), 1 HelpSpot ticket (17964), 1 wall-failure (arch3)
#   - AuthErrorClassifier.swift: 0 Crashlytics issues, 0 HelpSpot tickets
#   ...
```

## When this lands fully

Trigger: either (a) Crashlytics MCP gains file-level filtering, or (b) a heuristic file-inference pass produces good-enough signal in practice.

Until then, the agent has to ask explicitly — `cm_check` / `crashlytics_list_events` / `helpspot_triage_queue` — when it suspects relevance.

## Related

- Demo doc `03-improvements-roadmap.md` #12 — production-observability feedback loop
- `.forgeos/wall-failures/derived-improvements.md` — C2 row
- ForgeOS DNA feedback file (`/Users/mauricework/Desktop/forgeos-dna-vision-feedback.md`) — ask #6 SessionStart DNA surfacing is the ForgeOS-side equivalent
