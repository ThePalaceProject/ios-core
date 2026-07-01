---
date: 2026-07-01
pr: "swarm_495a88d9 (near-miss)"
source: near-miss
reviewer_ids: []
changeset_id: ""
wall: hook
walls: [hook, verify-pr]
severity: high
wall_status: proposed
applied_in: ""
detector_script: ""
detector_status: queued
no-detector: ""
name: false-green-empty-diff
type: evolving
status: active
created: 2026-07-01
last_refresh: 2026-07-01
freshness_window: 365d
owners: [general]
description: Diff-consuming detectors return exit 0 (green) on empty/absent input, masking real findings; wrapper exit codes sourced from a trailing command instead of the gate.
---

# False green from empty-diff detector input — a gate that can't fail provides no signal

## Finding (verbatim from reviewer / bug report)

During swarm_495a88d9 integration, `python3 scripts/check-blast-radius.py --quiet`
was run standalone and returned **exit 0** ("green"). The real `#if DEBUG`
finding (`RemoteFeatureFlags.swift` `isSideLoadingEnabled`, BR-2 high) was NOT
surfaced until `scripts/verify-pr.sh` piped the true `git diff BASE...HEAD` into
the same detector, which then correctly reported the finding and BLOCKED.

Separately, the orchestrator's own `verify-pr` wrapper printed
`=== verify-pr exit code: 0 ===` while the script had actually exited 1 — the
`0` came from a trailing `tail`, not from `verify-pr.sh`.

## What actually happened

`check-blast-radius.py` (and its sibling M1 detectors) default to reading the
unified diff from **stdin**. When invoked with no piped input (empty stdin),
the parser sees zero hunks, finds zero violations, and exits 0. That is
indistinguishable from "ran against the real diff and found nothing." A reviewer
or orchestrator running the detector directly to "spot-check" gets a false
all-clear. The finding only survived because a *different* invocation path
(verify-pr) happened to feed the real diff.

The wrapper case is the same class one layer up: a compound shell command
(`gate >> log; echo "exit $?"; tail log`) reports the exit status of the last
command in the pipeline (`tail`, always 0), not the gate. The green is an
artifact of how the result was read, not of the result.

Both are the green-board-contract failure mode from CLAUDE.md: a board that can
be green without the check having actually run trains everyone to trust a signal
that isn't there.

## Walls that should have caught it (and why they didn't)

- **hook / detector**: the detector treats "no input" as "no violations." It has
  no notion of "I was asked to scan but given nothing to scan," so it cannot
  distinguish an empty diff (legitimately nothing to check) from absent input
  (misinvocation) — and both collapse to exit 0.
- **verify-pr**: verify-pr itself invoked the detector correctly (real diff), so
  it did eventually catch the finding. The gap is that the detector is *also*
  used interactively/by reviewers/orchestrators, where the empty-stdin path
  produces a confident false green that suppresses follow-up.

## Proposed permanent fix

Make diff-consuming detectors **fail loudly on absent/empty input** rather than
pass. Concretely, in `scripts/_checklib.py` `read_diff()` (shared by
check-blast-radius / check-contract-reconciliation / check-superpartner-spectrum
/ check-adjacency-staleness / check-intent-recorded):

- If stdin is a TTY (no pipe) OR the resolved diff text is empty AND no explicit
  `--allow-empty` flag was passed, exit **2** (usage/error) with
  `ERROR: no diff on stdin — pass --diff <file> or pipe a diff; refusing to
  report green on empty input`.
- Add `--allow-empty` for the genuine "docs-only / empty diff" case so callers
  that *intend* an empty diff opt in explicitly (verify-pr's docs-only branch).

And for wrappers: any script that runs a gate and reports its status must
`GATE_RC=$?` immediately after the gate and echo/propagate `$GATE_RC` — never
let a trailing `tee`/`tail`/`grep` become the reported exit code. Add a
`bash -n` + shellcheck-style lint in `tooling-checks.yml` that flags
`<gate> ...; echo ... $?` patterns where an intervening command runs before `$?`
is captured.

The fix makes "green on empty input" **structurally impossible**: a detector
asked to scan nothing errors instead of passing.

## Detector script

**Script:** `scripts/check-detector-empty-input-guard.py` (queued — harness-side)
**Tests:** `scripts/tests/test_check_detector_empty_input_guard.sh`
**Wired into:** `.github/workflows/tooling-checks.yml` (runs against every
committed detector); `scripts/verify-pr.sh` tooling section.

**What it catches (one paragraph):** asserts that every `scripts/check-*.py`
which reads a diff exits nonzero when invoked with empty stdin and no
`--allow-empty`. The test harness pipes `/dev/null` into each detector and fails
if any returns 0. This is a meta-detector over the detectors themselves —
appropriate because the failure class is "the gate can't fail," which is only
observable by adversarially feeding the gate nothing.

**False-positive escape hatch:** `--allow-empty` on the detector invocation
(documented in each detector's `--help`) for the legitimate docs-only path.

**Severity (high) and rationale:** high — a silently-passable gate degrades the
entire green-board contract; every other detector's trustworthiness depends on
"green means it ran."

**Coverage measured at landing:** [queued — to be filled when the detector lands].

## Application log

- 2026-07-01 — entry filed from swarm_495a88d9 retro (near-miss; the real
  finding was caught by the correct verify-pr invocation, so nothing shipped —
  but the false-green path is a latent trust hole).

## Related entries

- Shares the green-board-contract root cause with
  [ws0-inert-quiescence-gate](2026-06-11-ws0-inert-quiescence-gate.md) (a gate
  that passed while inert). Both: "a gate is unverified until a planted
  violation / adversarial input makes it fail."
