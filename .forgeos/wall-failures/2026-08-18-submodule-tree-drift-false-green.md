---
date: 2026-08-18
source: near-miss
walls: [verify_before_done, test-fixtures-match-production-bytes]
severity: high
wall_status: open
---

# submodule-tree-drift-false-green

## Finding

From the `review:qa_test` verdict on PP-4724 tip `3c6e86bfb`:

> **Blocking (validation): the green run compiled the wrong toolkit.** The commit
> records pointer `1adbe833`, but the submodule *files* on disk in
> `wt-pp4724-w4/ios-audiobooktoolkit` are byte-identical to `d956b7bb` (develop's
> old pointer). Missing on disk: `@MainActor` on `StreamingCapablePlayer` and on
> `LCPStreamingProvider.setupStreamingFor`, `@MainActor` on
> `AudiobookPlaybackModel`, and #217's `nonisolated remainingWallClock`. So
> "24 tests / 115 toolkit compile tasks" is evidence about the *pre-bump*
> toolkit — where the protocol is nonisolated and a nonisolated witness is
> trivially legal. The central compile-time claim of this PR is unverified.

Three consecutive runs were reported as verification. All three compiled a
different tree than the commit recorded.

## What actually happened

The change under test was "make the app compile against a main-actor-isolated
toolkit". The only thing that could falsify it was compiling against the toolkit
the commit pins. That is precisely what never happened.

Two mechanisms combined, and neither is visible from inside the worktree:

1. **`harness worktree setup-ios` COPIES the submodule** from the canonical
   checkout at `ios-core/ios-audiobooktoolkit`. Whatever commit that checkout
   happens to sit on wins, silently overwriting anything materialized in the
   worktree. The canonical checkout sat at `d956b7bb` — develop's pointer, not
   the branch's.
2. **A linked worktree's submodule cannot report its own drift.** Its `.git` file
   reads `gitdir: ../.git/modules/ios-audiobooktoolkit`, which does not resolve
   from a worktree, so every submodule-aware git command there errors out
   instead of warning. `git -C <sub> log`, `git submodule status`, `git status`
   — all silent or fatal, none informative.

It looked correct because every signal that is normally trustworthy was present:
`** TEST SUCCEEDED **`, 24 tests, 0 failures, and 115 toolkit Swift compile
tasks in the log. The compile-task count had even been adopted earlier in the
same session as the *fix* for a previous stale-artifact miss, which is what made
it persuasive. It measures that a toolkit was compiled, never which one.

## Walls that should have caught it

- **verify_before_done** — passed. It asks whether verification ran, not whether
  it ran against the artifact the commit records.
- **"clear DerivedData before believing a cross-module result"** (learned earlier
  the same day, from an ios-core build that linked a stale prebuilt framework) —
  applied faithfully, and irrelevant. DerivedData was clean every time; the
  SOURCE was wrong.
- **"115 toolkit compile tasks" as proof of a real rebuild** — actively
  misleading. It confirmed compilation happened and was read as confirming
  *what* compiled.
- **The reviewers** — the architect approved the same tip, verifying comments
  against source (correctly) but drawing inferences from the same false build
  results. Only the qa_test reviewer diffed the files.

Nothing mechanical existed at any layer that compares a submodule's working
tree against its recorded gitlink.

## Proposed permanent fix

`~/harness/bin/verify-submodule-tree <superproject> <submodule> [files...]`

Reads the gitlink from `git ls-tree HEAD <submodule>`, resolves the canonical
object store via `git -C <canonical-sub> rev-parse --absolute-git-dir` (the
`.git` file must be resolved BY git — hand-building `.git/modules/<name>` is
wrong and was the first version's bug), and diffs the on-disk files against
`<pinned-sha>:<file>`. Exits non-zero with the re-materialization command.

Two usage rules, both learned the hard way:

- Run it **before** the build AND **again after**, because the copy can be
  clobbered mid-run. The after-check is what caught the clobber that the
  before-check had already cleared.
- Re-materialize with `git --git-dir=<store> archive <sha> | tar -x -C <path>`,
  not `git worktree add`. A worktree gets replaced by the copy; plain files
  survive until something overwrites them, and the after-check catches that.

Guard proved by reintroducing the defect: overwriting one file with the
`d956b7bb` version makes it report
`DRIFT: PalaceAudiobookToolkit/Player/StreamingResourceProvider.swift differs
from 1adbe833e` and exit non-zero; restoring makes it report `ok`.

Still open: it is a manual preflight, not wired into `harness test`. Wiring it
there — fail the run when the tree does not match the gitlink — is what would
make the failure structurally impossible rather than merely detectable.

## Application log

- 2026-08-18 — detector written and proved against the real drift. Canonical
  checkout moved to `1adbe833` so copies are correct. PP-4724's verification
  redone with before/after assertions; both reviewers independently confirmed
  the on-disk tree matches the pin.
- Not yet applied: automatic invocation from `harness test`.
