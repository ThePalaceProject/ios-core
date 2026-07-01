---
date: 2026-07-01
pr: "swarm_495a88d9 (near-miss)"
source: near-miss
reviewer_ids: []
changeset_id: ""
wall: orchestrator
walls: [orchestrator, implementer]
severity: medium
wall_status: proposed
applied_in: ""
detector_script: ""
detector_status: no-detector
no-detector: "The gap is a process/coverage gap (whole-tree lints run too late in the swarm loop), not a code pattern a static script can scan Palace source for. The fix is an orchestrator gate + implementer-prompt clause, and the lints themselves already exist (AppContainer/AccountsManager IsolationLintTests) — the detector is those tests, run at the right time."
name: isolation-lint-integration-only
type: evolving
status: active
created: 2026-07-01
last_refresh: 2026-07-01
freshness_window: 365d
owners: [general]
description: Whole-tree isolation lints are invisible to per-implementer DoD in isolated worktrees; violations only surface at integration, after all implementers report READY.
---

# Cross-file isolation lints are invisible to per-implementer DoD

## Finding (verbatim from reviewer / bug report)

`verify-pr.sh --quick` on the merged branch:

```
AccountsManagerIsolationLintTests.testNoBareAccountsManagerOutsideWhitelist:
  Bare `AccountsManager()` constructions found in PalaceTests/ outside the whitelist:
    Contract/SideloadImportContractTests.swift:55
    MyBooks/BookFileManagerSideloadResolutionTests.swift:76
    MyBooks/Sideload/SideloadedBookManagerTests.swift:66
AppContainerIsolationLintTests.testNoAppContainerProductionOutsideWhitelist:
    CatalogUI/SideloadedLaneTests.swift:183
    Book/BookRegistrySyncSideloadExemptionTests.swift:174,189
```

All implementers had reported READY with clean per-module DoD evidence (their own
test classes passed in isolation; their own `check-blast-radius`/name-vs-body
greps were clean). The isolation-lint failures surfaced only when the whole tree
was assembled at integration.

## What actually happened

Two meta-lints (`AppContainerIsolationLintTests`, `AccountsManagerIsolationLintTests`)
scan **every file under `PalaceTests/`** for bare `AccountsManager()` and
`AppContainer.production()` usages outside a whitelist. They are inherently
whole-tree: a single test file in violation fails the lint, but the lint can only
run meaningfully against the full assembled test target.

Each swarm implementer worked in an isolated worktree and self-verified per the
Definition of Done. But the DoD checks are all **file-scoped or module-scoped**
(SUT-instantiation grep on *their* files, mutation on *their* files, their test
classes pass). None of them runs a whole-tree scan — nor could it usefully, since
an implementer's worktree contains the sibling modules' code but the implementer
isn't looking at it. So four test files landed with real isolation violations
that every per-implementer wall passed.

The violations were real (bare `AccountsManager()` spawns a background
`loadCatalogs` that outlives the test — a documented pollution-flake source), not
false positives. They were caught at Phase 4.5 (orchestrator re-verify on merged
state), which is where they *should* be caught — but the swarm loop did not name
"run whole-tree lints on the merged state" as an explicit gate, so it was luck
(a full `verify-pr` run) rather than a required step.

## Walls that should have caught it (and why they didn't)

- **implementer / DoD**: every DoD check is file- or module-scoped by design. A
  cross-file lint ("no file in the whole tree does X") is structurally outside
  what a single implementer can self-verify — they'd have to scan modules they
  don't own. So the DoD is not the right wall for this class.
- **orchestrator**: Phase 4.5's skeptic pass lists many checks but does not
  explicitly require running the whole-tree isolation lints on the merged state.
  It caught them here only because a full `verify-pr --quick` was run and happens
  to include those test classes.

## Proposed permanent fix

1. **Swarm SKILL.md Phase 4.5**: add an explicit named gate —
   *"Run whole-tree lint classes on the merged state:
   `-only-testing:PalaceTests/AppContainerIsolationLintTests
   -only-testing:PalaceTests/AccountsManagerIsolationLintTests` (and any other
   `*IsolationLintTests` / meta-lint). These scan the full test tree and are
   invisible to per-implementer DoD; a green per-module DoD does not imply they
   pass."*
2. **Implementer prompt clause**: *"Cross-file lints (bare `AccountsManager()`,
   `AppContainer.production()` in test bodies — see `PalaceTests/MetaTests/*IsolationLintTests`)
   cannot be self-verified in your isolated worktree. Construct test dependencies
   via the sanctioned seams from the start: `PalaceWiringTestCase.makeFreshAccountsManager()`
   and mocks from `PalaceTests/Mocks/` (never bare `AccountsManager()` or
   `AppContainer.production()`)."* This shifts it left so integration rarely sees a
   violation at all.

## No detector — justification

See frontmatter `no-detector`. The enforcement mechanism already exists (the two
IsolationLintTests). The failure was *when* they ran, not a missing scanner. The
fix is orchestration + implementer-constraint, verified by the SKILL.md Phase 4.5
step and the implementer-prompt clause — not a new `scripts/check-*.py`.

## Application log

- 2026-07-01 — filed from swarm_495a88d9 retro. Violations were fixed in commit
  0b3230d3b (makeFreshAccountsManager + TPPBookRegistryMock + fresh OPDSFeedService
  + one justified `// MIGRATED-DEFERRED:` marker); no product code affected.

## Related entries

- Related to the per-implementer-vs-integration seam discussed in
  [arch1-fake-wiring-recurrence](2026-05-28-cs847892e8-arch1.md) (rigor
  improvements not present in the implementer's context at dispatch time).
