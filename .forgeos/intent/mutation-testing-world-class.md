---
name: mutation-testing-world-class
created: 2026-06-09
author: claude-opus-4-8
tracking: (none — internal tooling improvement; user-requested "make mutation testing faster + world-class")
related_prs: []
---

## Summary

Make Palace's custom Swift mutation tester (`scripts/palace_mutate.py`) faster
AND smarter. First-principles reframe: cost = #mutants × cost-per-run. The big
wins are **doing less work** and **measuring the right thing**, not just doing the
same work faster. We own the harness, not the technique (DeMillo–Lipton–Sayward
1978). Built as a dependency pipeline of mostly-disjoint components (coverage
engine → core engine → {parallel pool ‖ gate wiring} → docs/integration).

## Claims

- **Coverage-gating (keystone):** capture coverage from the baseline run palace_mutate
  already does (`-enableCodeCoverage YES -resultBundlePath`), parse via `xcrun xccov
  view --archive`, and never run mutants on lines no test executes (guaranteed
  survivors). Uncovered mutation points become a free coverage-gap report.
- **Tier-1 per-build flags** in `run_targeted_tests`: skip SPM resolution + plugin
  validation + index-store + parallel-testing per invocation. Env-overridable
  (`PALACE_MUTATE_XCB_EXTRA_FLAGS`, `PALACE_MUTATE_NO_FAST_FLAGS`). NOT `-quiet`
  (would break `any_tests_ran`).
- **Per-mutant incremental cache** (`.forgeos/mutation-cache/mutants/<leaf>.json`)
  keyed on host-line content + surrounding context (not line number) so editing one
  method only re-tests changed-line mutants. Whole-file cache kept as fast path.
- **Critical-path metric:** zero survivors tolerated on critical-path consequential
  mutants (cmp/bool/bound/retval/cond) → exit 1 regardless of kill rate. Added to
  report summary; enforced in verify-pr.sh.
- **Diff-scoped by default** for the PR mutation gate (`--mutation-whole-file`
  opts back to full at release).
- **Equivalent-mutant suppress-list** (`.forgeos/mutation-suppressions/<leaf>.json`)
  so known-unkillable survivors stop nagging.
- **Parallel worker pool** (`scripts/palace_mutate_parallel.py`): file-level fan-out
  across isolated git-worktree + pool-sim + own DerivedData workers. ISOLATION, not
  batching, so no result conflation. Gated on file count.
- Backward-compatible report schema (only ADD keys); preserved exit-code contract
  (0/1/2) and the verbatim `killed:/survived:` line verify-pr.sh greps.
- Every pure-logic addition has unit tests that do NOT invoke xcodebuild.

## Anti-claims

- Does **not** batch multiple mutants into one build/test run (masks survivors).
- Does **not** change the meaning of any existing report key or the kill-rate
  computation (still derived only from RUN mutants; uncovered/suppressed tracked
  separately).
- Does **not** remove the whole-file cache.
- Does **not** build mutant schemata (compile-once) — noted as future work.

## Scope deferral (explicit, not buried)

- **Test-selection (run only covering test methods per mutant) is wired but inert.**
  `mutate_coverage.tests_for_lines` returns `None` because reliable per-test
  attribution from an Xcode 26 xcresult is not yet solved; the core engine falls
  back to running the full resolved test class (today's behavior). The seam exists
  for when per-test coverage parsing lands. This is a graceful no-op, not a bug.

## Safety property

Coverage-gating and test-selection are OPTIMIZATIONS that degrade to today's
behavior on any failure: `covered_lines`/`tests_for_lines` return `None` on parse
error, missing bundle, or unsupported Xcode → the loop mutates every line / runs
the full class. The worst case is "no speedup," never "wrong verdict." This is
what made the change safe to make on critical quality tooling.

## Files in scope

- `scripts/mutate_coverage.py` (new) + `scripts/test_mutate_coverage.py` (new)
- `scripts/palace_mutate.py` + `scripts/test_palace_mutate.py`
- `scripts/palace_mutate_parallel.py` (new) + `scripts/test_palace_mutate_parallel.py` (new)
- `scripts/verify-pr.sh`, `scripts/post-mutation-pr-comment.py` + `scripts/test_post_mutation_pr_comment.py` (new)
- `docs/architecture/mutation-testing.md` (new)
- `.forgeos/mutation-suppressions/` (README + EXAMPLE)
