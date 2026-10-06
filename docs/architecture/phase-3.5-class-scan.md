---
name: phase-3.5-class-scan
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-06-05
freshness_window: 365d
owners: [general]
description: Phase 3.5 — class scan + detector codify (the wall-as-detector pattern)
---

# Phase 3.5 — Class scan + detector codify

**Status:** Active as of 2026-06-05.
**Applies to:** any fix that identifies a bug class, after the fix is written and before review. A new detector also has to meet the admission bar in `CLAUDE.md` ("Adding a detector").

## The rule

When a bug-class is identified during any phase of a fix — not just a single instance, but a **shape** that recurs at ≥2 call sites — Phase 3.5 fires. It runs a 5-step loop that produces three outputs:

1. **Wipe of current survivors** (the originally-reported instance plus any siblings the scan turned up).
2. **A detector script** at `scripts/check-<wall-id>.py` that catches future instances.
3. **A class record**: a numbered lesson in the area's `verification-checklist.md` that names the detector script (or states `no-detector: <specific reason>`).

Without (2), the wall has a hole. Without (3), the lesson is undiscoverable. Without (1), the PR is dishonest. All three are load-bearing.

## Why Phase 3.5 exists

Before this phase, postmortems proposed permanent fixes — but the fix was often a CLAUDE.md edit ("be more careful when adding new enum values") rather than a runnable check. CLAUDE.md edits are necessary but not sufficient. They depend on the next implementer reading the relevant section at the right time. A detector script does not.

Examples:

- A fake-wiring test in `AudiobookSessionManager` led to a proposed CLAUDE.md check and skill greps. The same class recurred one day later (a fake-wiring test in `TPPReauthenticator`). The recurrence was caught in review, and a name-vs-body detector was then added to the pre-review checks (retired 2026-09-30: it never flagged an instance after landing).
- PP-4161: unit tests pinned destination state without proving the production path. It took two layered escalations to catch, and the structural fix was a runnable pre-review check, not a docs change.

Phase 3.5 normalizes this: every recurring failure class that *can* be codified MUST be codified. The wall is the detector, not the postmortem.

## The 5-step loop

1. **Characterize** — write a 1-paragraph definition of the bug class, precise enough to grep.
2. **Scan** — Tier 1 (`grep`), Tier 2 (Explore subagent), or Tier 3 (dedicated script) — choose by class semantics.
3. **Triage** — for each survivor, classify (fix now / scope-defer / false-positive-annotate).
4. **Wipe** — apply the fixes in the PR. The PR fixes the class.
5. **Codify detector** — `scripts/check-<wall-id>.py` + tests + wire-in. Without this, the class can recur.

## 3-tier mechanism — when to use which

| Tier | Tool | Cost | Use when | Output |
|---|---|---|---|---|
| 1 | `grep` / `ripgrep` | ~1s | Class is a single literal call-pattern; no semantic disambiguation needed | `file:line` list |
| 2 | Explore subagent | ~10m | Class needs reading (which callers are intentional vs which are bugs); semantic disambiguation required | `file:line` + rationale per finding |
| 3 | Dedicated script at `scripts/check-<wall-id>.py` | One-time author cost + ~80% line coverage in tests | **Always — this is the permanent wall.** The one-time wipe catches *current* instances; the detector catches *future* ones. | Exit code (0/1) + grep-style finding lines |

Tier 3 is non-negotiable when the class is detector-eligible. Tier 1 and Tier 2 are scan-time choices, not substitutes for Tier 3.

## Discipline guardrails

- **Scope-deferral protocol applies.** If the class scan returns >5 survivors and fixing all of them would push the PR past 600 LOC, STOP with the BLOCKED + scope-reduction proposal per CLAUDE.md. The detector still lands in this PR — it catches the deferred sites at the next commit they touch.
- **Triage budget.** Small class (≤3 survivors, ≤50 LOC fix): instant fix, no follow-up ticket. Big class (>3 survivors or >50 LOC fix): scope-defer, file a follow-up ticket *and* land the detector. The detector + the deferred-follow-up ticket together IS the wall — neither alone is sufficient.
- **Detector > wipe.** When the choice is "spend the budget on the wipe vs the detector," prefer the detector. Future instances cost more than current ones.

## The first detector cohort

Six detectors made up the first cohort under Phase 3.5. Each is a runnable Python script wired into `scripts/verify-pr.sh` + `.claude/settings.json` PreToolUse hooks:

| ID | Detector | Catches | Source |
|---|---|---|---|
| D1 | `scripts/check-lcp-acquisition-recursive.py` | `defaultAcquisition.type ==` predicates that don't recurse through indirect chains | PP-4407 audit |
| D2 | `scripts/check-swiftui-placeholder-a11y.py` | SwiftUI text fields with placeholder strings but no `a11yLabel` / `accessibilityLabel` | PP-4408 audit |

Four more from the cohort (B foreign-host 401 scoping, D3 completion-nil-error
suppression, D4 NSError problem-doc preservation, D5 NotificationCenter observer
storage) were retired on 2026-09-30. None found a live instance when it landed
or flagged one afterwards; the two above each found live instances in the tree.
Their class write-ups were removed from the tree on 2026-09-30 and remain in
git history.

Each detector ships with:

- A test suite at `scripts/test_check_<wall-id>.py` (~80% line coverage convention)
- A fixture corpus at `scripts/tests/fixtures/<wall-id>/` (positive + negative cases)
- `scripts/verify-pr.sh` wire-in via the existing `run_m1_check` helper
- `.claude/settings.json` PreToolUse hook entry
- A class record in the area's verification-checklist that names the detector

## When NO detector is feasible

Some classes are genuinely semantic-only — they depend on runtime state in a 3rd-party library, on the timing of an AVPlayer callback, on whether a SwiftUI environment value is non-nil at first render. For these, no detector is acceptable, BUT the class record must state `no-detector: <specific reason>` and spell out:

- What semantic information is needed that grep / AST cannot encode.
- What runtime / dynamic / test-driven check substitutes (e.g., "this class can only be caught by simdrive replay of the lock-screen scenario; see `.simdrive/replays/chaos/lock-screen-engage.yaml`").
- Why a coarser static heuristic isn't worth the false-positive cost.

"Too hard" is not acceptable. Review rejects vague justifications.

## Cluster-vs-instance decision log

Phase 3.5 fires at the cluster level. A single instance — one fixed bug, no recurring shape — does not need a detector; it needs a behavior test. The decision rule:

- **Class:** the same call-pattern can produce the same defect in N callers. Detector required.
- **Instance:** the bug was a one-off (typo, off-by-one, wrong constant). Behavior test required; detector not warranted.

Borderline cases default to *class* — a false-positive detector that flags one extra commit is cheaper than a class that recurs in 6 months.

## Related

- [`CLAUDE.md`](../../CLAUDE.md) — "Adding a detector" and CI rule 4, the admission bar every new gate must meet
