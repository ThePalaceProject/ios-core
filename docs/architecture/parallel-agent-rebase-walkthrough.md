# Parallel-Agent Refactor — How We Ran 5 Concurrent Agents and Linearized the Stack

> A case study in how Phase 4 of the [architectural triad](./architectural-triad.md) was decomposed into 5 disjoint file partitions, run in parallel by independent agents on isolated branches, then merged into a single linear stack via cherry-pick + rebase. What worked, what we'd change.

## The setup

Phase 4 was service-layer singleton purge across many files. By the time we got there, the migration recipe was mechanical (Phases 2 and early Phase 4 had made every architectural decision):

- Drop `= .shared` defaults from init; require explicit deps.
- Add `convenience init(...:appContainer: AppContainer)` mirroring the field set.
- Internal `Foo.shared.bar` → `self.foo.bar`.
- For services in singleton init cycles (anything `MyBooksDownloadCenter.shared` or `TPPBookRegistry.shared` reads from), wrap as `() -> Foo` provider closures resolved lazily.
- Update test sites with sed/awk + manual fixes for capture-list errors.

That's mechanical churn. Mechanical churn parallelizes well — *if* you can guarantee no two agents touch the same file.

## File-partition strategy

We carved the remaining work into 4 disjoint partitions so no two agents could create a merge conflict:

| Agent | Files (no overlap with other agents) |
|---|---|
| `audiobook-services` | `Palace/Audiobooks/AudiobookSessionManager.swift`, `Palace/Audiobooks/PlaybackBootstrapper.swift` |
| `annotations-bookmarks` | `Palace/Reader2/Bookmarks/TPPAnnotations.swift` |
| `views-cleanup` | `Palace/AppInfrastructure/AppTabHostView.swift`, `Palace/Book/UI/BookDetail/BookDetailView.swift`, `Palace/CatalogUI/Views/CatalogLaneMoreView.swift`, `Palace/MyBooks/MyBooks/MyBooksView.swift`, `Palace/SignInLogic/SignInModalView.swift` |
| `download-center` (highest risk, run last) | `Palace/MyBooks/MyBooksDownloadCenter.swift`, `Palace/MyBooks/MyBooksDownloadCenter+Async.swift` |

The Phase 5 reducer agent ran *concurrently* with all four Phase 4 agents on its own branch — Phase 5 only touched `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (production), `Palace/Book/UI/BookDetail/BorrowReducer.swift` (new), `Palace/SignInLogic/AuthReducer.swift` (new), and the matching test files. Zero file overlap with any Phase 4 agent.

## The branch model

Each agent worked on its own git branch, all created off the same Phase 4 baseline:

```
develop
  └── epic/arch-triad-phase-3 (Phase 3 characterization-tests baseline)
       └── epic/arch-triad-phase-4-audiobook-services
       └── epic/arch-triad-phase-4-annotations-bookmarks
       └── epic/arch-triad-phase-4-views-cleanup
       └── epic/arch-triad-phase-4-download-center
       └── epic/arch-triad-phase-5
```

**No two agents pushed to the same branch.** The Xcode `pbxproj` merge conflicts that result from concurrent writes to the project file are notoriously hard to resolve cleanly — keeping each agent on its own branch made every conflict a deliberate human-driven merge rather than an unexpected git-mediated one.

Worktree-per-agent (`git worktree add`) gave each agent its own working directory off the same repo, so they could run `xcodebuild` builds independently without stepping on each other's `DerivedData`.

## The merge

After each branch finished:

1. **Review each branch independently** — eyeball the diff, run targeted tests on just that branch's changed files.
2. **Linearize via rebase**, in order of risk-from-low-to-high so simpler branches landed first as the next baseline:
   - `views-cleanup` first (no service-layer churn — pure routing-`.shared`-to-`@Environment`)
   - `audiobook-services` second
   - `annotations-bookmarks` third
   - `download-center` last (touches the 3,036 LOC god class)
3. **Re-run the full suite** on the merged tip. We expected a small flaky test (audiobook test-ordering shared-state pollution) that wasn't introduced by Phase 4. Verified by running the flaky test in isolation on both the pre-Phase-4 baseline and the merged tip — passed both times — confirming "not a regression."
4. **Re-audit `git grep -c '\.shared' Palace/`** to confirm trajectory.

## Cherry-picking across the stack to repartition by PR scope

After Phase 4 and Phase 5 had all landed locally, we noticed one Phase-4-flavored singleton kill (`MyBooksDownloadCenter.shared` static-let removal) had landed on the Phase 5 branch instead of the Phase 4 branch. The PR descriptions wanted this kill in the "Phase 1-4" PR, not the "Phase 5 reducers" PR.

The fix:

```bash
# 1. Backup both branches before the surgery
git branch backup/phase4-pre-cherry epic/arch-triad-phase-4
git branch backup/phase5-pre-rebase  epic/arch-triad-phase-5

# 2. Cherry-pick the misplaced commit onto Phase 4
cd .claude/worktrees/phase-4-worktree
git cherry-pick <sha-of-singleton-kill-commit-on-phase-5>

# 3. Reset Phase 5 to drop the now-duplicate commit
cd <main-worktree>
git checkout epic/arch-triad-phase-5
git reset --hard <sha-of-commit-just-before-the-misplaced-one>

# 4. Rebase Phase 5 onto the new Phase 4 tip (which now includes the cherry)
git rebase epic/arch-triad-phase-4
```

This worked because the singleton-kill commit had **zero file overlap** with the Phase 5 reducer commits — verified ahead of time:

```bash
git show --name-only --pretty="" <singleton-kill-sha> | sort > /tmp/singleton-files.txt
git show --name-only --pretty="" <reducer-1-sha>     | sort > /tmp/reducer-1-files.txt
git show --name-only --pretty="" <reducer-2-sha>     | sort > /tmp/reducer-2-files.txt
comm -12 /tmp/singleton-files.txt /tmp/reducer-1-files.txt   # → empty (no overlap)
comm -12 /tmp/singleton-files.txt /tmp/reducer-2-files.txt   # → empty (no overlap)
```

Pre-flight checks like that turn risky stack surgery into deterministic surgery.

## What worked

1. **Disjoint file partitions made conflicts impossible by construction.** Worth front-loading the design effort to pick partitions where no two branches touch the same file. The Xcode `pbxproj` is the most obvious shared-state file, but BookDetailViewModel, AppContainer, and a handful of other "infecting" files also need explicit single-owner assignment.
2. **Worktree-per-agent gave each branch its own DerivedData.** Builds didn't step on each other; no spurious "module recompilation" interference.
3. **Backup branches before any rewrite operation.** Saved real work twice during the rebase walkthrough — once when an `--onto` rebase produced an unexpected commit ordering, once when a cherry-pick conflict resolution was wrong on the first attempt. `backup/phase4-trunk-pre-rebase` and `backup/phase5-pre-rebase` were one `git reset --hard` away from a clean recovery.
4. **Linearizing risk-low-to-high.** When the high-risk branch (download-center) finally landed on top of an already-stable stack, every conflict was clearly between *its* changes and *the new tip* — not between the high-risk changes and some earlier branch's changes muddled in.
5. **Pre-flight `comm -12` file-overlap check** before any cherry-pick across branches. Five seconds of bash to know whether your cherry-pick will be clean.
6. **Per-target commits** so the merge into the linear stack stayed atomically reviewable. Every commit on the final stack is a single migration's-worth of work — easy to bisect, easy to revert.

## What we'd change

1. **The mutation testing run that gated PR #867 was misconfigured the first time.** We passed `--tests PalaceTests/SignInLogic` (a directory) instead of `PalaceTests/AuthReducerTests` (the XCTest class). Xcode silently reported success with zero tests run, producing a false 0% kill rate. This would have blocked the PR if we hadn't caught it. Lesson: the mutation runner should detect "0 tests executed" and report ERRORED rather than SURVIVED. Tracked as a follow-up to the runner script.
2. **The pre-PR `gh pr create` hook was silently picking the wrong changeset** for any branch other than the one with the most-recently-created changeset. Server's `?branch=` filter didn't work; the hook never client-side filtered. Fixed in PR #868 — both the hook and the same-pattern grep counter bugs in the verify-pr script.
3. **More upfront characterization tests for `TPPSignInBusinessLogic` would have unblocked Phase 5's `AuthReducer` integration.** We have the reducer with 21 tests but it's not yet wired into the production sign-in business logic, because that 758-LOC ObjC-bridged class has 0 dedicated tests. The phase ordering should be: Phase 3 characterization tests → Phase 5 reducer extraction → reducer integration into the production class.
4. **The Phase 4 `parallel agent` plan didn't include explicit verification gates between agent landings.** When the download-center branch finally landed on top, the full-suite re-run was the first signal that the merged stack worked. A per-merge "run targeted tests on just the changed files" gate would have caught issues earlier and cheaper.

## Generalization

This pattern works when:

- The migration recipe is mechanical (every architectural decision is already locked in)
- File partitions can be cleanly drawn (no two branches touch the same file)
- The full-test-suite is the safety net (you can run it on every merge step)

It's the wrong tool when:

- The work requires architectural decisions per file (parallel agents will produce inconsistent decisions)
- File overlap is unavoidable (you'll spend more on conflict resolution than you save on parallelism)
- The test suite is slow or unreliable enough that you can't run it on every merge step

For Palace's Phase 4 — mechanical singleton migration on disjoint files with a 5-min full-suite — it was the right tool.
