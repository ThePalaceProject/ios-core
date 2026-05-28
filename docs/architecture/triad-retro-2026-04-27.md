---
name: triad-retro-2026-04-27
type: evolving
status: active
created: 2026-04-27
last_refresh: 2026-05-06
freshness_window: 365d
owners: [general]
description: "Architectural Triad — Retrospective (2026-04-27)"
---

# Architectural Triad — Retrospective (2026-04-27)

> Retrospective on the [architectural triad epic](./architectural-triad.md) at the moment Phases 1–5 landed in PRs #866 + #867. What we delivered, what surprised us, what we'd change.

## What landed

| Metric | Before (origin/develop) | After (PR tips) | Change |
|---|---|---|---|
| `.shared` call sites in `Palace/` | 732 | 564 | −168 (−23%) |
| `static let shared` declarations | 59 | 54 | −5 |
| `AppContainer` services | 5 | 15 | +10 |
| `@Environment(\.appContainer)` injection sites | 1 | 7+ | +6 |
| Tests passing | 5,608 | 5,649 | +41 |
| Tests failing | 0 | 0 | — |
| Tests skipped (Keychain-entitlement-gated) | 7 | 7 | — |

Five killed `static let shared` declarations: `NavigationCoordinatorHub`, `AppTabRouterHub`, dead `BookActionHandler`, `MyBooksDownloadCenter`, plus `BookCellModelCache` decoupled from the init-cycle deadlock (kept alive for one default-arg site that's a small follow-up).

Three new types of architectural tooling:

- `Store<State, Action, Environment>` (~70 LOC) — closure-based reducer + Effect type
- `AppContainer.production()` — single composition root with private `_cached` static-let to break init cycles
- Reducer-as-pure-function pattern, with `HoldsReducer` (11 tests), `BorrowReducer` (19 tests), `AuthReducer` (21 tests) as the canon

Zero behavior changes intended; smoke-tested clean against the build sim (app boots, OPDS catalog loads HTTP 200 across 5 concurrent feed requests, no crash in a 30-second window).

## What worked

### 1. AppContainer as a single composition root with `_cached`

The breakthrough moment was realizing the historical `BookCellModelCache.shared` ↔ `production()` init-cycle deadlock was solvable with one private `static let _cached: AppContainer = build()`. Before that change, every full-suite test run was at risk of a 30+ second hang because two singletons each tried to construct each other during their first access. After: `production()` constructs the entire dependency graph exactly once, deterministically, on first access. Every subsequent caller gets the cached instance.

The factory pattern matters: `AppContainer.production()` is now the single auditable line where `.shared` reads happen during composition. Everything else takes deps via the constructor.

### 2. Reducer-as-pure-function over reducer-as-Store-wrapper

The first instinct was to migrate ViewModels by wrapping them in a `Store<State, Action, Environment>`, which would have meant rewriting all the `@Published`-mutating tests. Instead, the `BorrowReducer` integration uses a `snapshotBorrowState() / reduce / applyBorrowState` round trip — the VM still owns its `@Published` properties; the reducer just computes the next state given the current snapshot. All 81 existing `BookDetailViewModelTests` survived the integration without touching the test file.

Consequence: future critical-path migrations can land the *reducer* (with dedicated pure-function tests) before deciding whether to also normalize the test patterns to wrap the VM in a Store. Two phases instead of one, but each phase is reviewable on its own.

### 3. Lazy provider closures broke participant init cycles

`BookRegistrySync` reads `MyBooksDownloadCenter` at runtime, but `MyBooksDownloadCenter` reads `TPPBookRegistry` at construction. Direct injection deadlocked. The fix: pass `() -> MyBooksDownloadCenter` provider closures into `BookRegistrySync`'s init; resolve lazily on first use. This pattern is now the canonical solution for the cycle-prone services and is reusable for `TPPUserAccount` ↔ `AccountsManager` in a future phase.

### 4. Per-target commits, atomically reviewable

Every commit on the merged stack is one migration's-worth of work — `MyBooksViewModel: explicit deps + AppContainer convenience init`, `Holds: extract state machine into HoldsReducer + 11 reducer tests`. No god commits. The diff for each is small enough to read end-to-end. Bisecting against any test failure in the stack is mechanical.

### 5. Mutation testing the new reducers

Pre-merge mutation pass on the two new reducers killed 6/6 mutants (100%) — every conditional flip and return-value flip in both `BorrowReducer` and `AuthReducer` is caught by the dedicated reducer tests. This is exactly the bar the project's "critical path tests must be air-tight" rule asks for.

### 6. Parallel-agent partitioning for Phase 4

5 concurrent agents on disjoint file partitions, merged into a linear stack. Saved meaningful wall-clock time without producing any cross-agent merge conflict. See [parallel-agent-rebase-walkthrough.md](./parallel-agent-rebase-walkthrough.md) for the full pattern.

## What surprised us

### 1. The first mutation test run reported false 0%

The mutation runner accepts `-only-testing:<TargetName>/<XCTestClassName>`. We passed `<TargetName>/<directory>` which xcodebuild silently treats as "match no test class — succeed with zero tests run." The runner saw "test process exited 0, no failures" and graded every mutation as SURVIVED.

A 0% kill rate across 6 mutants on critical-path code would have blocked the PR if we hadn't dug in. The lesson is generic: **any test infrastructure that grades a result by "did the test process succeed" needs to also assert that the test process *executed* tests.** The mutation runner is being patched in a follow-up to detect "0 tests executed" and report ERRORED rather than SURVIVED.

### 2. Server-side `?branch=` filter on the changeset API didn't work

The pre-PR governance hook was looking up the active branch's changeset via an API query that the server silently ignored — so it returned an unfiltered list and the hook took `items[0]`, which was usually a stale changeset on a totally different branch. The hook had `|| true` in its invocation, so it never actually blocked PR creation, but it printed misleading "[ForgeOS] Found changeset cs_XXXXXX for branch <wrong-branch>" diagnostics.

Fixed in PR #868 by porting the harness's already-correct client-side filter into the in-repo hook. Lesson: when a remote API has filter parameters that look like they should work, verify them against a known case before trusting downstream consumers.

### 3. The `verify-pr.sh` "build FAIL" was a bash idiom bug

8 places used `grep -c "X" || echo "0"`. When `grep -c` finds 0 matches it prints `0` AND exits 1; the `||` fallback then APPENDS another `0`, producing the literal `0\n0`. Subsequent integer comparisons (`[ "$VAR" -eq 0 ]`) bail with `[: 0\n0: integer expression expected`.

Symptom: every clean build was reported as `[FAIL] build — 0\n0 Swift compilation errors`. Fixed in PR #868 — `|| true` instead of `|| echo "0"`, with `${VAR:-0}` defaults at comparison sites.

This bug had been latent in the script for weeks. Nobody noticed because the verify-pr.sh result was non-blocking advisory; we noticed only because we ran the script in this round and read the log carefully.

### 4. `c12e45abb` (a singleton-kill commit) ended up on the wrong branch

The "MyBooksDownloadCenter: kill .shared static-let" commit landed on Phase 5 instead of Phase 4 because it was authored after Phase 5 had already started. Fixing it required a cherry-pick onto Phase 4 + a `git reset --hard` + rebase on Phase 5. We pre-flighted with `comm -12` to confirm zero file overlap, made backup branches before the surgery, and the whole thing took ~10 minutes. Lesson reinforced: **when stack surgery is well-pre-flighted, it's deterministic; when it's not, it's a recipe for losing work.**

## What we'd change

### 1. Phase 3 first

We deferred Phase 3 (characterization tests for `TPPSignInBusinessLogic` and the borrow flow) and went straight to Phase 5's reducer extraction. The `AuthReducer` exists with 21 tests, but it's NOT wired into `TPPSignInBusinessLogic` because that class has 0 dedicated tests and rewiring it without a safety net is reckless.

Net effect: we have a half-finished reducer migration. The reducer is the *spec*, but the production code still uses the legacy switch-case logic. The integration is gated on Phase 3 work that's now blocking.

Lesson: **respect the phase order for critical-path work.** Characterization tests aren't a "we'll get to that" — they're the prerequisite for safe migration.

### 2. Mutation-test all critical-path code earlier

Mutation testing was a pre-merge ask on PR #867, after the reducers had landed. Running it during Phase 1b's `HoldsReducer` work would have established the kill-rate bar and given us a faster signal on whether the reducer-test pattern actually catches regressions. (It does — 100% kill rate on the two later reducers proves the pattern.)

### 3. Smaller scope in #866's PR description

PR #866 ended up with 27 commits across Phases 1, 1b, 2, 3 (audit only), and 4. That's a wide diff to review. A future epic should land each phase as its own PR — even if they're all merged in sequence the same week — so the review surface stays small per PR.

The pragmatic counterargument: stacked PRs have their own friction in GitHub (auto-rebase only kicks in on merge, not on PR sync). For Phase 1b → 2 → 3 in this codebase, the per-phase PRs would have been ~5–10 commits each and clearly easier to review.

### 4. Move the ForgeOS governance tooling out of the public repo

The `scripts/forgeos-*.sh` and the references in `CLAUDE.md` to mandatory governance gates are maintainer-internal tooling that doesn't belong in a public open-source repo. Outside contributors see scripts that require an API key they don't have, and a CLAUDE.md that tells them to follow a workflow they can't follow. Tracked as a separate cleanup. The governance work itself is great (the gate model produced real discipline this round); it's just published in the wrong place.

## Process improvements for next epic

1. **Stack PR review more carefully.** Smaller per-phase PRs even if they all merge the same day.
2. **Phase 3 characterization tests are not optional.** Don't start a critical-path reducer extraction until the legacy code has a behavior pin.
3. **Mutation-test the first reducer.** Establish the kill-rate bar at the first reducer, not at the last one.
4. **Verify CI advisory tooling.** When the verify-pr or governance hook says "FAIL" or "found changeset X", read the diagnostic and verify it matches your mental model. Latent bugs in advisory tooling silently misdirect.
5. **Pre-flight stack surgery with `comm -12` file-overlap checks.** Five seconds of bash converts uncertainty into determinism.
6. **Backup branches before any rewrite.** `backup/<branch>-pre-<operation>` is cheap insurance.

## Reference

- [#866 — Architectural Triad: DI adoption, Store pattern, singleton purge (Phases 1-4)](https://github.com/ThePalaceProject/ios-core/pull/866)
- [#867 — Architectural Triad: Borrow + Auth reducers (Phase 5)](https://github.com/ThePalaceProject/ios-core/pull/867)
- [#868 — Fix two latent bugs in governance scripts](https://github.com/ThePalaceProject/ios-core/pull/868)
