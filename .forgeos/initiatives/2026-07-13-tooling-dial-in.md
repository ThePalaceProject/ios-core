# Tooling Dial-In Initiative — pre-Sprint 79

**Date:** 2026-07-13 · **Owner:** Maurice (solo) · **No PR — local branch only.**

## Context

Solo, agent-driven, local-first, cost-conscious. Sprint 78 retro found: the
verification *infrastructure* is strong, but enforcement rests entirely on the
agent PreToolUse hook (Channel A) — **the detectors ARE the wall.** That model is
correct for an agent-driven shop, but it makes two audit findings load-bearing:

1. Some **blocking** detectors were never tested → an invisible hole in the wall.
2. Detectors are static → they caught **~0%** of real shipped runtime/build bugs
   in the wall-failure backtest. Both Sprint-78 self-regressions (#1226 launch
   crash, #1225/#1218 second-target build breaks) are outside detector reach.

This initiative dials the tools in before Sprint 79. All work is LOCAL (scripts/,
docs/, .forgeos/) — no Palace/ production Swift, no framework build, no CI push.

## Work items

- **WI-1 — Test the untested detectors.** Add a pytest in `scripts/tests/` for each
  of the 6 untested detectors, priority on the two BLOCKING ones. Every test must
  assert BOTH: (a) a real violation is caught (non-zero exit), AND (b) a clean diff
  passes (exit 0) — the CLAUDE.md rule-#4 clean-path assertion. Model after an
  existing sibling (`test_check_foreign_host_401_scoping.py`).
  - `check-blast-radius.py` — **BLOCK**
  - `check-contract-reconciliation.py` — **BLOCK**
  - `check-test-name-vs-body.py` — DoD #1
  - `check-superpartner-spectrum.py` — warn
  - `check-adjacency-staleness.py` — warn
  - `check-discipline-nudge.py` — nudge
- **WI-2 — Both-target build gate.** Add an off-by-default pre-push hook script that
  builds Palace + Palace-noDRM, documented as "run before pushing any AppContainer/
  concurrency/startup change." Covers the #1225/#1218 second-target-break class that
  no static detector can catch.
- **WI-3 — Promote or retire the warn-only detectors.** Dry-run `superpartner-spectrum`
  and `adjacency-staleness` against recent history; if zero false positives, wire a
  promotion path (block on high-severity/critical-path, keep low-severity warn);
  otherwise document why they stay warn. No silent half-on state.
- **WI-4 — Prune lying docs.** `docs/Testing/Coverage_Roadmap.md` (stale: forbidden
  workspace build, wrong sim, contradicts "honest 35%") → delete or rewrite to match
  reality. Fix the stale hook-symlink description in CLAUDE.local.md.
- **WI-5 — DECISION (Maurice): test pollution.** Not fixed tonight. Choose:
  (a) invest — pool-responsiveness probe + local per-shard fresh process, then revive
  the parked `greenboard-enforcement-deferred` gate; or (b) accept retry-mask —
  delete the reverted scaffolding, document green = "passes within 3 retries." The
  current parked-tag limbo is the one state to leave.

## WI-3 decision — 2026-07-13 (soak evidence + call)

**Verdict: BOTH stay fully warn-only. No promotion. No script edits.** Neither
detector meets CLAUDE.md rule #4's "soaked with ZERO false positives" bar. A
false-positive blocker is worse than a warn, and both would produce routine
blocks on legitimate work that agents would learn to bypass (`--no-block` /
`// no-superpartner:` / ignore) — reopening a hole in the wall via habituation.

### `check-superpartner-spectrum.py` → KEEP WARN (do not block-on-high)

Soak: working-tree diff + last 20 commits, `--dry-run` at high floor.
- Working tree: **1 HIGH** — `AudiobookSessionPresenter.swift:559 func chapterProgress`.
- Last 20 commits: **5 of 20 fired HIGH**, 13 HIGH findings total:
  - `0437af6e4` ×3 `addBookmark` · `c4bee439c` ×3 `setPlaybackRate`
  - `0ae5ebf9a` ×3 `setSleepTimer` · `ea9221571` ×3 `seek` · `5a99261e6` ×1 `fire`
- Every HIGH is `Palace/Audiobooks/` (critical path → auto-HIGH per the path
  globs), and every one is either a thin protocol accessor on
  `AudiobookSessionManaging` + its `AudiobookSessionManager` impl
  (`seek`/`setPlaybackRate`/`setSleepTimer`/`addBookmark` — pass-throughs to the
  toolkit) or a local closure helper (`fire`).

Why not promote: these are *true positives by the detector's definition* (no
test in the SAME diff) but NOT defects worth blocking. Two structural reasons:
(1) the check only sees the current diff, so the common test-later / test-at-the-
manager-seam workflow (function in commit X, behavior test in commit Y) reads as
a miss; (2) critical-path auto-HIGH means every audiobook accessor trips the
block, not just risky logic. Block-on-high would have blocked ~25% of recent
commits on this branch — a nuisance rate that trains bypass. The summary-nudge
value ("did you add a test?") is real; keep it advisory. Mutation testing
(`palace_mutate.py`, DoD #5) remains the actual proof-of-catch on critical paths.

Re-evaluate to promote only if: (a) the accessor false-alarm is cut by
exempting thin protocol-witness pass-throughs, and (b) it runs branch-clean
(zero HIGH) across a 20-commit window. Not there yet.

### `check-adjacency-staleness.py` → KEEP WARN (structurally warn-only)

Soak: working-tree diff + last 30 commits, `--quiet`.
- Working tree: **0** ("no removed declarations to check").
- Last 30 commits: **4 fired**, with runaway false-positive clusters:
  - `0c0ee344e` **N=211** on removed name `label`
  - `c70e6b0f7` **N=50** on removed name `minimize`
  - `6b865f222` N=3 · `d565ab9da` N=2 (`configureAudioSession`)

Why not promote: the design greps *all surviving comments* for the bare removed
identifier with `\b<name>\b`. Common words (`label`, `minimize`) match hundreds
of unrelated comment lines (SwiftUI `.label`, accessibility labels, `Label`
views, "minimize allocations" prose) that have nothing to do with the rename.
The N=211/N=50 clusters are ~all false positives. The script's own docstring
already states it is warn-only because "renames vs deletions are not mechanically
distinguishable from the diff alone." This is a genuinely-useful *nudge* after a
targeted rename of a distinctive symbol, but it is structurally unfit to block —
promotion is not on the table without an identifier-distinctiveness/allowlist
filter that the current design lacks. Keep exit-0 warn as written.

## Definition of Done (WI-1..4)

- pytest suite green; each new test asserts catch + clean-pass.
- Build-gate script passes `bash -n`; wired off-by-default with a documented flag.
- Warn-only detectors either promoted (with dry-run evidence) or documented as
  intentionally-warn.
- Stale docs corrected or removed.
- Committed to a dedicated local branch; audiobook working-tree edits untouched; no push, no PR.

## WI-2 — both-target build gate: how to enable

Delivered: `scripts/pre-push-both-target-build.sh` (passes `bash -n`; repo-tracked,
mirroring `scripts/pre-push-test-gate.sh` — note `scripts/hooks/` is a harness symlink
and is NOT committable, so the gate lives directly under `scripts/`).
It builds BOTH schemes with `xcodebuild -project Palace.xcodeproj` on the
iPhone 16 Pro sim, build-only (no test): `Palace` (full DRM) then
`Palace-noDRM` (open-source, mirroring `scripts/xcode-build-nodrm.sh`'s
code-signing opt-out). This closes the #1225/#1218 second-target-break class —
a change that compiles in `Palace` but breaks `Palace-noDRM` — which no static
detector can catch.

OFF BY DEFAULT (mirrors `pre-push-test-gate.sh`). Enable for a single push:

```bash
ENABLE_BOTH_TARGET_BUILD_GATE=1 git push ...
```

Bypass once while enabled: `SKIP_BOTH_TARGET_BUILD_GATE=1 git push ...`.

Run it before pushing any AppContainer / concurrency (Swift 6 isolation,
Sendable) / app-startup / target-conditional (`#if`) change — the diffs that
can differ across the two targets. Chains `git lfs pre-push` first, so it is a
safe drop-in as `.git/hooks/pre-push`. **It should be wired into the agent
pre-push path** (export `ENABLE_BOTH_TARGET_BUILD_GATE=1` there, or chain the
script from the agent's pre-push hook) so those risk-bearing pushes get the
both-target compile automatically. Framework-absent worktrees (no
`carthage bootstrap` / submodule init) are treated as a non-blocking WARN, same
as the test gate — CI remains authoritative there.
