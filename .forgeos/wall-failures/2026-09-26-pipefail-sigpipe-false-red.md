---
date: 2026-09-26
pr: "#TBD (arch/phase-a-rearm-gates)"
source: near-miss
reviewer_ids: []
changeset_id: ""
wall: implementer
walls: [implementer, verify-pr]
severity: medium
wall_status: applied
applied_in: arch/phase-a-rearm-gates
detector_script: "scripts/check-pipefail-early-exit-reader.py"
detector_status: queued
no-detector: ""
name: pipefail-sigpipe-false-red
type: incident
---

# A pipeline into an early-exiting reader reports failure on a match

## What happened

Closing a reviewer finding on `check-package-tests-wired.sh` — that a
commented-out CI step still satisfied the wiring match — I stripped full-line
YAML comments before matching, by piping one grep into a quiet grep.

The gate immediately reported **all four correctly-wired packages as UNWIRED**.
The same construct matched fine when run by hand in the shell.

The quiet grep exits at its first match. The upstream grep still has buffered
output, takes SIGPIPE, and exits 141. `set -o pipefail` — present at the top of
the script — makes the pipeline's status the rightmost non-zero, so a successful
match returns 141 and the `if` takes the false branch.

## Why it is worse than a plain bug

It is **size-dependent**. If the upstream's remaining output fits in the pipe
buffer (64KB on macOS) it finishes writing before the pipe closes, exits 0, and
the identical code works. So:

- it passes on small fixtures and fails on real files;
- it depends on *where in the stream the match falls* — a match near the end
  leaves nothing to buffer, so the same file can pass or fail depending on which
  package is being checked;
- a pytest written with a short fixture, or with the matching lines last, cannot
  see it. My first `test_many_wired_packages_still_pass` had both problems and
  passed against the defective gate.

It fails toward red here, which is the survivable direction. The same construct
in a negated guard, or anywhere the pipeline's success is the permissive branch,
fails toward green.

## The fix

Hoist the transform out of the pipeline into a command substitution, then match
against a here-string. A command substitution has no reader to close the pipe
early. `grep -c` with a numeric test, or simply dropping the quiet flag, also
work.

## Detector

Queued as `scripts/check-pipefail-early-exit-reader.py`, not waived: a shell-lint rule for a pipeline whose reader exits early
(the quiet grep flag, and the line-limiting utilities, which share the shape)
inside any script that sets pipefail. Both are common and near-always wrong in a
conditional. Tractable as a static pattern over the committed shell scripts, so
`no-detector` does not apply — it is simply not built yet, and lands in the
follow-up rather than growing this PR further.
