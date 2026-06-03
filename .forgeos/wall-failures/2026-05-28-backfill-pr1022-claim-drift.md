---
date: 2026-05-28
pr: "#1022"
source: retro-observation
reviewer_ids: []
changeset_id: cs_pr1022_backfill
wall: contract
walls: [contract, verify-pr, hook]
severity: high
wall_status: proposed
applied_in: ""
contributing_docs: []
name: backfill-pr1022-claim-drift
type: snapshot
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: PR#1022/#1023 — "removes SignInModalHostingController" PR-body claim never reconciled with diff (propagated across two stacked PRs)
---

# PR#1022/#1023 — claim-drift on SignInModalHostingController removal (backfill finding)

## Finding (verbatim from reviewer / bug report)

Module C's backfill audit ran `python3 scripts/check-contract-reconciliation.py` against PR#1022 and PR#1023:

```
# PR#1022 (head 7c68bb17, base 77758ff3):
1 claim(s); 1 unsupported.
UNSUPPORTED: pr-body: claim=REM args=('SignInModalHostingController',):
  no `-class|struct|...|protocol SignInModalHostingController` line and
  no `SignInModalHostingController.*` file deletion found in diff

# PR#1023 (head b3ee8e61, base 7c68bb17, stacked on #1022):
2 claim(s); 2 unsupported.
UNSUPPORTED: pr-body: claim=REM args=('SignInModalHostingController.',)
UNSUPPORTED: pr-body: claim=REM args=('SignInModalHostingController',)
```

The PR bodies of both #1022 and #1023 contain language framing `SignInModalHostingController` removal as a deliverable. Neither diff actually removes the file or the declaration. PR#1023 is stacked on #1022, so the unaddressed claim propagates forward.

## What actually happened

Wave 2 (PR#1022) scoped two parallel changes: (a) the `.accountNotFound` enum-split work (real diff content), and (b) "apply arch1 rigor fixes" — described in the PR body as including the removal of the `SignInModalHostingController` shim. The shim removal was a follow-up that the swarm planned but didn't land in the wave-2 timebox; the PR body wasn't updated to reflect the reduced scope. The body still said "removes `SignInModalHostingController`."

Wave 3 (PR#1023) was the next stacked swarm. The author reused PR-body boilerplate that included the same "removes `SignInModalHostingController`" promise plus a more specific second mention (e.g. `SignInModalHostingController.` followed by a method name). That swarm also didn't land the removal — it focused on the SignInModal sheet-presenter foundation work instead.

Net effect: two consecutive PR bodies promise a removal that the diffs don't perform. Anyone reading the PR description would believe the shim is gone; anyone running the actual app or reading the codebase would find it still present. This is **the exact gap class the M1 reconciler exists to catch.**

## Walls that should have caught it (and why they didn't)

- **contract (PR-body reconciliation)**: didn't exist as a CI gate. Module A introduces `check-contract-reconciliation.py`. Module C wires it into `verify-pr.sh` (gate `contract_reconciliation`) and the pre-commit hook (the M1 floor's `contract_reconciliation` check). Going forward, **any** PR with a body claim that the diff doesn't satisfy fails verify-pr and is refused at commit time (for ≥10 prod LOC diffs).
- **verify-pr**: pre-M1 had no claim-vs-diff reconciliation. Now does.
- **hook (pre-commit)**: pre-M1 only blocked secret-shaped files. M1's floor block runs the reconciler with `block-on-fail` at the ≥10 LOC threshold; both #1022 and #1023 are well over the threshold.
- **reviewer**: the architect reviewer would likely accept "removal language" in a PR body without diffing against the actual change set — that's not their lens. Mechanical reconciliation is the right wall.

## Proposed permanent fix

Already applied via M1:

1. ✅ `scripts/check-contract-reconciliation.py` (Module A) — parses `removes X` / `deletes X` / `migrates Y to Z` / `renames X to Y` / `adds field A to type B` from commit/PR body / intent file, reconciles against the diff. Exit 1 on any UNSUPPORTED claim.
2. ✅ `scripts/verify-pr.sh` — new `contract_reconciliation` gate; PR push fails the gate.
3. ✅ `scripts/git-hooks/pre-commit` M1 floor block — `block-on-fail` at ≥10 prod-LOC; both PR diffs are >>10 LOC; refused without `--no-verify`.
4. ✅ `.claude/skills/intent/SKILL.md` — author writes intent file BEFORE coding; intent file's `## Claims` section is fed to the reconciler.

Result: a future PR that says "removes `SignInModalHostingController`" in the body but doesn't actually remove it is mechanically blocked at commit + push + verify-pr. The author must either land the removal OR update the body to drop the claim.

## Application log

- 2026-05-28 — finding surfaced by M1 backfill audit (`.forgeos/audits/backfill-2026-05-28.md`).
- 2026-05-28 — fix applied in M1 itself.
- TBD — verify the next PR in the stack (#1024+) either lands the removal or updates the body language.

## Related entries

- This is a NEW pattern with no prior wall-failure analog — the "claim-drift" cluster originates here. Future occurrences will link back to this entry.
- Indirectly related to `.forgeos/wall-failures/2026-05-27-pr1018-arch1.md` (scope-reduction-without-acknowledgement is the family) but the mechanism is PR-body-level not test-level.
