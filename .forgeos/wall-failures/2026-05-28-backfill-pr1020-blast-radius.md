---
date: 2026-05-28
pr: "#1020"
source: retro-observation
reviewer_ids: []
changeset_id: cs_pr1020_backfill
wall: blast-radius
walls: [blast-radius, verify-pr, hook]
severity: high
wall_status: proposed
applied_in: ""
contributing_docs: []
name: backfill-pr1020-blast-radius
type: snapshot
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: PR#1020 — PlaybackReadinessGate.swift 7 new public declarations on a critical-path Audiobooks file
---

# PR#1020 — PlaybackReadinessGate public-surface cluster (backfill finding)

## Finding (verbatim from reviewer / bug report)

Module C's backfill audit ran `python3 scripts/check-blast-radius.py` against the head commit of PR#1020 (`77758ff3`, branch `swarm/swarm_c8fcab76-scaffold` vs `origin/develop`). 7 BR-1 high-severity findings, all in:

```
Palace/Audiobooks/PlaybackReadinessGate.swift:57: BR-1: high: new `public`/`open` declaration on prod file
Palace/Audiobooks/PlaybackReadinessGate.swift:68: BR-1: high
Palace/Audiobooks/PlaybackReadinessGate.swift:116: BR-1: high
Palace/Audiobooks/PlaybackReadinessGate.swift:128: BR-1: high
Palace/Audiobooks/PlaybackReadinessGate.swift:135: BR-1: high
Palace/Audiobooks/PlaybackReadinessGate.swift:142: BR-1: high
Palace/Audiobooks/PlaybackReadinessGate.swift:157: BR-1: high
```

`Palace/Audiobooks/` matches the critical-path regex (`Palace/Audiobooks/` is in `CRITICAL_PATH_REGEX` per the contract). Under the M1 floor's `block-always` mode, this commit would NOT have been allowed to land.

## What actually happened

The wave-1 close-out swarm introduced `PlaybackReadinessGate` to coordinate audiobook player readiness across multiple consumers (open, refresh, CarPlay). The gate's transition methods and state accessors were marked `public` to allow test-side wiring tests to drive the gate through real consumers (the new round-trip wiring tests mandated by CLAUDE.md "State-machine wiring tests must exercise round-trips" guidance).

The problem: `public` exposes those transition methods to **every** Palace caller, not just the test target. A future PR could call `gate.markReady()` from a non-consumer site and silently break the readiness invariant. The blast-radius scanner correctly flags this as high-severity because the surface is now misuse-reachable from production code.

Equivalent test-driveability could have been achieved with `@testable import Palace` + `internal` declarations, or with a `private(set) var state: State` plus an `internal` `transition(to:)` method scoped to the file. The PR took the more permissive route without justifying it.

Compounding factor: the fake-wiring-test recurrence cataloged in `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` is on this exact file — `AudiobookSessionManager.swift:684-710` cited zero coverage from a test claiming to exercise the wired path. The over-public `PlaybackReadinessGate` made the test surface tempting (it's easy to spy on a public method directly), which encouraged the fake-wiring shape.

## Walls that should have caught it (and why they didn't)

- **blast-radius**: didn't exist as a CI gate when PR#1020 was authored. M1 introduces it.
- **verify-pr**: pre-M1 had no public-surface gate. Now does.
- **hook (pre-commit)**: pre-M1 pre-commit hook only checked for secret files. M1 adds the floor block with always-block on critical-path files. PR#1020 would have hit `block-always` mode.
- **reviewer (forge-architect-reviewer)**: the architect reviewer's prompt focused on logic-flow correctness, not on visibility-modifier hygiene. Module B's `forge-blast-radius-reviewer` agent is the structural fix at the reviewer layer.

## Proposed permanent fix

Already applied via M1:

1. ✅ `scripts/check-blast-radius.py` (Module A) — exit 1 on any BR-N high finding.
2. ✅ `scripts/verify-pr.sh` — new `blast_radius` gate; PR push would fail the gate.
3. ✅ `scripts/git-hooks/pre-commit` M1 floor block — `Palace/Audiobooks/` matches the critical-path regex; mode = `block-always`; commit is refused unless `--no-verify` with rationale.
4. ✅ `.claude/agents/forge-blast-radius-reviewer.md` (Module B) — universal reviewer always included regardless of gate template.

Result: a future PR introducing 7 new `public` on `Palace/Audiobooks/PlaybackReadinessGate.swift` is mechanically impossible without explicit override (`--no-verify` + rationale) or downgrade to `internal`.

## Application log

- 2026-05-28 — finding surfaced by M1 backfill audit (`.forgeos/audits/backfill-2026-05-28.md`).
- 2026-05-28 — fix applied in M1 itself.
- TBD — verify zero recurrence on the next PR touching `Palace/Audiobooks/`.

## Related entries

- `.forgeos/wall-failures/2026-05-28-backfill-pr1018-blast-radius.md` — sibling cluster on `TPPReauthenticator+Reauthenticating.swift` (other critical-path leak).
- `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` — fake-wiring-test recurrence on the SAME file (`AudiobookSessionManager`). The over-public surface here is a contributing factor; this entry is the proximate test-side cause.
