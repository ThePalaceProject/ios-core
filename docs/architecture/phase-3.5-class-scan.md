---
name: phase-3.5-class-scan
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-10-06
freshness_window: 365d
owners: [general]
description: Class-scan detectors - what they are and where they run
---

# Class-scan detectors

Some bugs are a **class**: the same call shape can produce the same defect at
several call sites. Others are an **instance**: a one-off typo, off-by-one or
wrong constant. An instance needs a behavior test. A class may also need a
detector, a script that flags the shape in new code so it cannot recur unseen.
A new detector must meet the admission bar in [`CLAUDE.md`](../../CLAUDE.md)
("Adding a detector" and CI rule 4).

## The detectors

Each is a Python script in `scripts/` with a pytest suite in `scripts/tests/`.
The list and each detector's severity are in
`scripts/pre-commit-phase35-detectors.sh` (the `DETECTORS` array). Each
script's header describes the class it targets.

| Script | Flags | Severity |
|---|---|---|
| `check-lcp-acquisition-recursive.py` | LCP-acquisition predicates that do not walk nested indirect acquisitions (PP-4407, PP-4454) | block |
| `check-swiftui-placeholder-a11y.py` | SwiftUI placeholder and label sites that read as disabled UI and give VoiceOver the placeholder as the label (PP-4421) | warn |
| `check-unsynchronized-sendable-mock.py` | test mocks declared `@unchecked Sendable` with unsynchronized mutable state, driven concurrently by a test | block |
| `check-auth-challenge-async-form.py` | authentication-challenge delegate callbacks in `Palace/` not written in the async form (PP-4895) | block |
| `check-raising-unarchiver.py` | `NSKeyedUnarchiver.unarchiveObject(with:)` and `(withFile:)`, which raise an ObjC exception Swift cannot catch | block |
| `check-opaque-blob-egress.py` | a whole opaque payload interpolated into something that leaves the device | block |
| `check-comment-hygiene.py` | source comments that break the writing conventions in `CLAUDE.md` | block |

## Where they run

- **`scripts/verify-pr.sh`**, the pre-PR self-check, runs all seven. The first
  six run through `run_phase35_detector`; comment hygiene has its own step.
- **CI** (`.github/workflows/tooling-checks.yml`) runs every pytest suite in
  `scripts/tests/` (step "pytest detector suite") and the hook fixture test
  `scripts/tests/test_pre_commit_phase35_detectors.sh`, and runs comment
  hygiene (`check-comment-hygiene.py`) over the whole tree on every pull
  request. The other six detectors are tested in CI but not run against the
  pull request's tree.
- **`scripts/pre-commit-phase35-detectors.sh`** runs them against the staged
  diff on `git commit`. It reads a Claude Code PreToolUse hook payload on
  stdin, and the tracked `.claude/settings.json` does not register it, so it
  runs only where someone has wired it locally.
<!-- audit-verified -->
