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

**Status:** Active as of 2026-06-05 (swarm_162a3219).
**Enforcement:** mandatory phase inside `/rigorous-fix` between Phase 3 (skeptic) and Phase 4 (forge-review); cross-referenced from `/swarm` Phase 4 (integrator class-scan reconciliation) and Phase 4.5 check 6.4.

## The rule

When a bug-class is identified during any phase of a fix — not just a single instance, but a **shape** that recurs at ≥2 call sites — Phase 3.5 fires. It runs a 5-step loop that produces three outputs:

1. **Wipe of current survivors** (the originally-reported instance plus any siblings the scan turned up).
2. **A detector script** at `scripts/check-<wall-id>.py` that catches future instances.
3. **A wall-failure entry** at `.forgeos/wall-failures/YYYY-MM-DD-<short-id>.md` with `detector_script:` populated (or `no-detector: <specific reason>`).

Without (2), the wall has a hole. Without (3), the lesson is undiscoverable. Without (1), the PR is dishonest. All three are load-bearing.

## Why Phase 3.5 exists

Before this phase, wall-failure entries proposed permanent fixes — but the fix was often a CLAUDE.md edit ("be more careful when adding new enum values") rather than a runnable check. CLAUDE.md edits are necessary but not sufficient. They depend on the next implementer reading the relevant section at the right time. A detector script does not.

The pattern recurs across the catalog. Examples:

- `2026-05-28-cs847892e8-arch1.md` (fake-wiring-test in `AudiobookSessionManager`) — proposed CLAUDE.md DoD check #7 + skill greps. Same class recurred 1 day later (`2026-05-28-cs9a267b63-arch1.md`, fake-wiring-test in `TPPReauthenticator`). The recurrence was caught only after `scripts/check-test-name-vs-body.py` landed as a runnable detector wired into the Phase 4.5 skeptic-pass.
- `2026-06-03-cs_e0f586cc-modC-get-routing.md` (PP-4161 — Module C unit tests pinned destination state without proving production path) — required two layered escalations to catch. The structural fix was check 6.5 in `swarm/SKILL.md` Phase 4.5, not a docs change.

Phase 3.5 normalizes this: every wall-failure that *can* be codified MUST be codified. The wall is the detector, not the postmortem.

## The 5-step loop

See `.claude/skills/rigorous-fix/SKILL.md` Phase 3.5 for the operational checklist. In summary:

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

## The 6 detectors landed in swarm_162a3219

This swarm produced the first detector cohort under Phase 3.5. Each is a runnable Python script wired into `scripts/verify-pr.sh` + `.claude/settings.json` PreToolUse hooks:

| ID | Detector | Catches | Source wall-failure |
|---|---|---|---|
| B | `scripts/check-foreign-host-401-scoping.py` | 401-as-credentials-stale dispatch from non-account hosts | `2026-06-05-pr1018-icarus-cross-host-logout.md` (PR #1044) |
| D1 | `scripts/check-lcp-acquisition-recursive.py` | `defaultAcquisition.type ==` predicates that don't recurse through indirect chains | PP-4407 audit |
| D2 | `scripts/check-swiftui-placeholder-a11y.py` | SwiftUI text fields with placeholder strings but no `a11yLabel` / `accessibilityLabel` | PP-4408 audit |
| D3 | `scripts/check-completion-nil-error-suppression.py` | `completion?(nil, "msg", "..")` failure-passthrough that drops the error | PP-4419 audit |
| D4 | `scripts/check-nserror-problemdoc-preservation.py` | `NSError(domain: TPPErrorLogger...)` constructions that discard server problem-doc fields | PP-4400 audit |
| D5 | `scripts/check-notification-observer-storage.py` | `addObserver` calls whose returned token isn't stored — leaks on dealloc | TPPAppDelegate scan |

Each detector ships with:

- A test suite at `scripts/test_check_<wall-id>.py` (~80% line coverage convention)
- A fixture corpus at `scripts/tests/fixtures/<wall-id>/` (positive + negative cases)
- `scripts/verify-pr.sh` wire-in via the existing `run_m1_check` helper
- `.claude/settings.json` PreToolUse hook entry
- A wall-failure entry with `detector_script:` populated and `detector_status: built`

## When NO detector is feasible

Some classes are genuinely semantic-only — they depend on runtime state in a 3rd-party library, on the timing of an AVPlayer callback, on whether a SwiftUI environment value is non-nil at first render. For these, `detector_status: no-detector` is acceptable, BUT the entry's frontmatter must populate `no-detector: <specific reason>` and the body's `## No detector — justification` section must spell out:

- What semantic information is needed that grep / AST cannot encode.
- What runtime / dynamic / test-driven check substitutes (e.g., "this class can only be caught by simdrive replay of the lock-screen scenario; see `.simdrive/replays/chaos/lock-screen-engage.yaml`").
- Why a coarser static heuristic isn't worth the false-positive cost.

"Too hard" is not acceptable. The reviewer pass on the entry will reject vague justifications.

## Cluster-vs-instance decision log

Phase 3.5 fires at the cluster level. A single instance — one fixed bug, no recurring shape — does not need a detector; it needs a behavior test. The decision rule:

- **Class:** the same call-pattern can produce the same defect in N callers. Detector required.
- **Instance:** the bug was a one-off (typo, off-by-one, wrong constant). Behavior test required; detector not warranted.

Borderline cases default to *class* — a false-positive detector that flags one extra commit is cheaper than a class that recurs in 6 months.

## Related

- `.claude/skills/rigorous-fix/SKILL.md` — Phase 3.5 operational checklist
- `.claude/skills/swarm/SKILL.md` — Phase 4.0a + Phase 4.5 check 6.4 (class-scan reconciliation)
- `.forgeos/wall-failures/README.md` — "Detector requirement" subsection
- `.forgeos/wall-failures/TEMPLATE.md` — `## Detector script` body section
- `.forgeos/wall-failures/derived-improvements.md` — cluster-fix tracking
- `docs/architecture/superpartner-spectrum.md` — adjacent pattern (warn-only test-pairing floor)
- `docs/architecture/critical-path-review-policy.md` — adjacent pattern (push-gate)
