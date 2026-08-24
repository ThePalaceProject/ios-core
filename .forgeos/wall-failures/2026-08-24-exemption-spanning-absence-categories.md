---
date: 2026-08-24
pr: "#TBD (docs/doc-routing-and-drift-gates)"
source: near-miss
reviewer_ids: []
changeset_id: ""
wall: TDD
walls: [TDD, verify-pr, reviewer]
severity: high
wall_status: applied
applied_in: c0b7babe8
detector_script: scripts/check-doc-references-resolve.py
detector_status: built
contributing_docs: []
name: exemption-spanning-absence-categories
type: evolving
status: active
created: 2026-08-24
last_refresh: 2026-08-24
freshness_window: 365d
description: Two sessions independently tried to exempt "the file isn't there" as one category — one fix would have silenced the detector, the other laundered a false positive into the baseline
---

# Exemption spanning both absence categories — a gate that reports success while going blind

## Finding

Two sessions, working the same detector within twenty minutes, each produced a
change that made `check-doc-references-resolve.py` stop reporting real drift.
Neither was caught by reading. One was caught by running the gate; the other by a
peer reading the diff.

> *"My first cut exempted anything `git check-ignore` called ignored — general,
> mechanical, no hand-maintained list, and it would have switched your detector
> off. `regression-report.sh`, `generate-regression-report.py` and
> `tools/ledger/codeatlas.yml` are gitignored BECAUSE they were extracted to the
> harness, so every doc still pointing at them goes silent."*

> *"THE 4 FINDINGS ARE MY BUG, NOT DOC DRIFT — do not baseline them. Baselining
> would launder a false positive into tolerated drift and keep the false
> negative."*

## What actually happened

Archiving `.forgeos/swarms/**` deleted files that four docs referenced by bare
name (`├── manifest.yaml` inside ASCII layout diagrams). The gate went red. Two
different repairs were attempted:

**Repair A (baseline).** The four entries were added to
`doc-references-baseline.json` and justified as "prose references to a runtime
artifact." Plausible — they *are* runtime artifacts — and wrong, because the
finding was not drift at all. `WORKFLOW_RE` resolves a bare filename against any
tracked basename **anywhere in the tree**, so those references had only ever
passed because the archive coincidentally contained files named `manifest.yaml`.
Baselining recorded a false positive as tolerated drift and preserved the false
negative underneath it: a genuinely broken `deploy.yml` reference would still
resolve against any unrelated `deploy.yml`.

**Repair B (near-miss).** The alternative was to exempt any path that
`git check-ignore` reports as ignored. This is the more attractive fix by every
usual heuristic — general, mechanical, no hand-maintained list, no literals to
rot. It is also the one that would have blinded the detector to its primary
target. Files extracted to the maintainer-local harness are gitignored *because*
they were removed; a doc still pointing at one is the exact rot this gate was
built to catch, and the rule would have silenced every such reference at once.

Both repairs share one root cause: **absence of a file from the tree is two
categories that look identical.**

| Absence means | Example | Verdict |
|---|---|---|
| Written **tomorrow** — runtime artifact, or deliberately-untracked secret | `.forgeos/swarms/<id>/manifest.yaml`, `APIKeys.swift` | compliance |
| Deleted **yesterday** — extracted to the harness, or moved by a refactor | `regression-report.sh`, `Palace/Book/Models/TPPBookRegistry.swift` | the rot |

Any exemption expressed as a *property both categories satisfy* — "is it
gitignored", "is it a runtime artifact" — is simultaneously a false positive for
one and a false negative for the other. The generality that makes such a rule
attractive is precisely what lets it span the boundary.

## Walls that should have caught it (and why they didn't)

- **TDD.** The detector's own suite had no control for the extracted-script case.
  Every test asserted that a *present* file passes and an *absent* one blocks, so
  a change redefining "absent" passed all of them. The suite tested the arms that
  existed, not the distinction the arms depend on — the wall-is-closed-over-
  written-code failure, applied to a category rather than a state cell.
- **verify-pr.** Structurally cannot see Repair A: baselining a finding is the
  supported way to make this gate pass. A tolerated entry and a fixed one are
  indistinguishable to the exit code.
- **reviewer.** Caught Repair A, and only because a second session happened to be
  reading the same detector. Nothing mechanical compared the justification
  ("runtime artifact") against the actual cause (bare-name resolution).

What did catch Repair B was the gate's **stale-baseline arm** — the check that
fails when a baselined entry starts resolving. Mid-weakening, it named the three
harness-extracted references as newly resolving. A gate reported its own
weakening, by name, to the person performing it.

## Permanent fix

Landed in `c0b7babe8`:

1. **Exempt by construction, narrowly.** `RUNTIME_ARTIFACT_PREFIXES =
   (".forgeos/swarms/",)` — a literal path prefix — plus one literal bare name.
   A prefix cannot span the absence boundary; a property query can.
2. **Two controls for the category NOT exempted.**
   `test_gitignored_but_EXTRACTED_script_still_blocks` and
   `test_gitignored_but_EXTRACTED_workflow_still_blocks` assert that a gitignored
   *extracted* target still fails. These exist because the mistake was made; the
   names carry the reason.
3. **The four baseline entries were pruned**, not kept.

Verified by re-introducing Repair B as a mutant in a throwaway worktree:
`test_gitignored_but_EXTRACTED_workflow_still_blocks` fails with
`assert 0 == 1` — a named assertion failure, not a build error. The guard bites.

## Detector script

**Script:** `scripts/check-doc-references-resolve.py`
**Tests:** `scripts/tests/test_check_doc_references_resolve.py` (36 cases)
**Wired into:** `.github/workflows/tooling-checks.yml`; `scripts/verify-pr.sh`;
pinned by `scripts/tests/test_doc_reference_gate_wiring.sh`.

**What it catches:** a tracked doc naming a script, workflow, or source path that
does not exist. Exemptions are literal and enumerated — an ellipsis path, a
deliberately-untracked secret by suffix, a documented placeholder by exact path,
a runtime-artifact directory by prefix — never a computed property of the target.

**False-positive escape hatch:** write a maintainer-local path as `~/harness/...`
so it reads as deliberately-not-here; or, for genuine pre-existing drift,
`--update-baseline` (which refuses to grow without `--accept-new`).

**Severity — high:** the failure mode is a gate that passes while blind. Nothing
turns red, so the loss of coverage is invisible until someone follows a dead
pointer.

## Application log

- 2026-08-24 — Repair A (baseline) landed in `862fdf105`, reverted in `c0b7babe8`.
- 2026-08-24 — Repair B caught pre-landing by the stale-baseline arm; narrow fix
  + two controls landed in `c0b7babe8`.

## Not fixed

The bare-name looseness stands: `deploy.yml` with no directory component still
resolves against any tracked basename anywhere. It is a deliberate trade-off
(prose usually names a workflow without its path) and is now the known residual
false negative rather than an unexamined one.

## Related entries

- [`2026-06-11-ws0-inert-quiescence-gate.md`](2026-06-11-ws0-inert-quiescence-gate.md)
  — a gate that passed three times while completely inert. Same class: the gate
  ran, reported success, and enforced nothing. Caught there by a planted
  violation; caught here by the stale-baseline arm. Both say the same thing —
  **a gate is unverified until something makes it RED on purpose.**
- [`2026-06-05-swarm162a3219-arch1.md`](2026-06-05-swarm162a3219-arch1.md)
  — `OUT=$(... || true); EXIT=$?` always reads 0, so a detector hook silently
  passed every finding. Same shape one layer down: the mechanism reports success
  regardless of the result.
