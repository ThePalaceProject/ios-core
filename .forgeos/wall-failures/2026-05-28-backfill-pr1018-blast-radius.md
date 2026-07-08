---
date: 2026-05-28
pr: "#1018"
source: retro-observation
reviewer_ids: []
changeset_id: cs_pr1018_backfill
wall: blast-radius
walls: [blast-radius, verify-pr]
severity: high
wall_status: applied
applied_in: "PR #1025"
contributing_docs: []
name: backfill-pr1018-blast-radius
type: snapshot
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: PR#1018 — public-surface leak cluster (49 BR-1 findings) surfaced retroactively by M1 backfill
---

# PR#1018 — public-surface leak cluster (backfill finding)

## Finding (verbatim from reviewer / bug report)

Module C's backfill audit ran `python3 scripts/check-blast-radius.py` against the merged commit of PR#1018 (`f380e37c`) and surfaced **49 BR-1 findings**, all classified `high` severity ("new `public`/`open` declaration on prod file — justify or downgrade to `internal`"). After triaging out the ≈30 findings inside the `Palace/Packages/PalaceAuth/Sources/PalaceAuth/` SPM source tree (where `public` is structurally required for cross-target visibility), the surviving cluster of **≈19 high-severity findings** is in main-target files:

- `Palace/AppInfrastructure/Telemetry/AuthDecisionEvent.swift:29,32,34,43,48,64` (6 findings)
- `Palace/AppInfrastructure/Telemetry/AuthDecisionRecorder.swift:30,32,34` (3 findings)
- `Palace/SignInLogic/TPPReauthenticator+Reauthenticating.swift:*` (remaining; critical-path file)

## What actually happened

PR#1018 introduced a new auth-decision telemetry layer (`AuthDecisionEvent`, `AuthDecisionRecorder`) and an `AuthCoordinator` package surface. The author marked the telemetry types `public` so the package layer could observe them, but the telemetry types live in the **main `Palace` target**, not in an SPM package. The `public` declaration therefore exposes the symbols to the entire Palace link-image — far broader than the intended PalaceAuth-package observer surface.

Equivalent intra-target visibility would have been achieved by `internal` (the default), which still makes the symbols visible to both PalaceAuth (because PalaceAuth links Palace at runtime via the umbrella) and Palace itself. The `public` modifier added no functional benefit, only blast-radius surface.

The PR#1018 reviewer-block focused on **test-side fakeness** (arch1/arch2/arch3/qa1/qa2/qa3) — none of those entries flagged the production-side public-surface leak. The blast-radius lens wasn't part of the reviewer toolkit at that time.

## Walls that should have caught it (and why they didn't)

- **blast-radius**: didn't exist as a SoD reviewer or as a CI gate when PR#1018 was created. Module B introduces `forge-blast-radius-reviewer` and Module C wires `check-blast-radius.py` into `verify-pr.sh` and the pre-commit hook. Going forward, this finding class would always-block on the critical-path `TPPReauthenticator+Reauthenticating.swift` and warn on the non-critical telemetry files (still emitted, still in the verify-pr report).
- **verify-pr**: pre-M1 `verify-pr.sh` had no public-surface gate. Now it does.
- **reviewer (forge-architect-reviewer)**: the architect reviewer's prompt didn't explicitly call out the "public-surface justification" requirement. The PR's overall complexity (12,743 lines) made it easy for the reviewer to focus on logic-flow correctness and overlook visibility-modifier choices. Module B's blast-radius reviewer agent is the structural fix.

## Proposed permanent fix

Already largely applied via M1:

1. ✅ `scripts/check-blast-radius.py` lives at scripts/ as of Module A. Exit 1 on any high-severity BR-N finding.
2. ✅ Module C inserts the `blast_radius` gate into `scripts/verify-pr.sh` between `test_quality` and `coverage_floors`.
3. ✅ Module C inserts the M1 floor block into `scripts/git-hooks/pre-commit` — always-blocks on critical-path files (which include `Palace/SignInLogic/` covering `TPPReauthenticator+Reauthenticating.swift`).
4. ⏭️  **M2 follow-up:** teach `check-blast-radius.py` to recognize `Palace/Packages/<pkg>/Sources/<pkg>/` paths and either suppress BR-1 there or emit at `medium` severity (SPM `public` is still surface-exposed even if structurally required).

Result: any PR landing new `public` on `Palace/AppInfrastructure/Telemetry/*.swift` or `Palace/SignInLogic/TPPReauthenticator+Reauthenticating.swift` would be blocked at pre-commit time under the M1 floor.

## Application log

- 2026-05-28 — finding surfaced by M1 backfill audit (`.forgeos/audits/backfill-2026-05-28.md`).
- 2026-05-28 — fix applied in M1 itself (this swarm `swarm_M1_83be56fc`).
- TBD — verify zero recurrence on the next 3 multi-file PRs landing on critical paths.

## Related entries

- `.forgeos/wall-failures/2026-05-28-backfill-pr1020-blast-radius.md` — sibling cluster on `PlaybackReadinessGate.swift` (critical-path Audiobooks file).
- `.forgeos/wall-failures/2026-05-27-pr1018-arch1.md` and qa1-qa3 — same PR, different (test-side) failure modes.
