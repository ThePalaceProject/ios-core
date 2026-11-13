---
name: feature-branch-workflow
type: evolving
status: active
created: 2026-11-12
last_refresh: 2026-11-12
freshness_window: 365d
owners: [general]
description: Feature branches for multi-PR work, and why only their PR into develop runs the macOS CI
---

# Feature-branch workflow

**TL;DR:** Work that takes more than one PR lands on `feature/PP-XXXX-<slug>`
first. Sub-task PRs into that branch run only the Linux checks. The feature
branch's PR into `develop` runs the full macOS CI once, and merges with a merge
commit.

## The rule

| PR | macOS CI | Linux checks | Merge method |
|---|---|---|---|
| sub-task → `feature/**` | none | PR text, tooling checks | squash; the subject keeps `PP-XXXX: ... (#N)` |
| `feature/**` → `develop` | full | full | merge commit (`gh pr merge <num> --merge`) |
| single PR → `develop` | full | full | squash |
| `release/**`, `hotfix/**`, `main` | unchanged | unchanged | see [`release-merge-policy.md`](./release-merge-policy.md) |

- Create the feature branch from the tip of `origin/develop`, one per epic or
  multi-PR story. Sub-task branches start from the feature branch.
- Single-PR work (one bug, one small change, a dependency bump) still targets
  `develop` directly.
- Keep the feature branch current with `develop` only when GitHub reports a
  conflict, or right before opening its PR into `develop`.
- Merge every sub-task PR into the feature branch before the feature PR merges.
  A sub-task PR left open would otherwise have to be retargeted onto `develop`
  (see below).

## Why: the macOS queue

Measured in November 2026, one push to a code PR into `develop` starts about
eight macOS jobs and about 185 macOS minutes:

| Workflow | macOS minutes |
|---|---|
| Unit Tests (a build of ~17, then four shards of ~20-40) | ~123 |
| UI Journeys | ~27 |
| Thread Sanitizer | ~21 |
| NonDRM Build | ~13 |
| Ledger Analysis | ~1 |

The organization gets about five concurrent macOS jobs. At peak hours one push
fills the pool, and the next PR waits 30-105 minutes in the queue. Running the
macOS CI once per feature, not once per sub-task push, removes most of that
load without removing any check from what reaches `develop`.

## How the CI tells the PRs apart

Each macOS workflow with a `pull_request` trigger ignores PRs whose base is
`feature/**` (`branches-ignore`). A PR into any other base, including `develop`,
`main`, `release/**`, `hotfix/**` and work branches such as `feat/*` or `fix/*`,
still runs it. `ledger.yml` keeps its own, narrower filter: it runs only on PRs
into `main` and `develop`. `scripts/tests/test_macos_pr_base_branches.py` checks
both directions for every macOS workflow. `pr-hygiene.yml` and
`tooling-checks.yml` have no base filter and run on every PR.

`unit-testing.yml` has no `paths-ignore`, because a path-skipped workflow never
reports and a required check would wait forever. A base filter does not cause
that: a required check applies to PRs into the branch that requires it, and no
`feature/**` branch requires one.

GitHub reads the workflow files from the PR's merge result, so the filter
applies to every PR opened after this change is on `develop`.

### Retargeting a PR onto develop

Changing a PR's base sends an `edited` event. These workflows do not listen to
`edited`, because a title or body edit would then start a run, and with
`cancel-in-progress` it would cancel the run already going. So a PR moved from a
feature branch onto `develop` has no macOS run until it gets a new push or is
closed and reopened. Do one of those before merging it.

## What a sub-task PR is gated on

With no macOS CI on the sub-task PR, the local test run is the gate. Before a
sub-task PR merges into the feature branch:

- run `scripts/verify-pr.sh --quick` (or at least the test classes the change
  touches, plus mutation testing on the changed lines for a critical path);
- get the reviews a PR into `develop` would need.

Before the feature PR opens, run `scripts/verify-pr.sh --quick` on the feature
tip. The review of the feature PR covers the integration: conflict resolutions
and interactions between the sub-task PRs, not each sub-task again.

## Why the feature PR uses a merge commit

`scripts/check-release-fix-reconciliation.py` decides, commit by commit, whether
each fix on `develop` is on the release branch. It compares commits by patch
(`git cherry`) and matches a release commit to its forward-port by the `(#N)`
suffix in the subject. A merge commit keeps every squashed sub-task commit on
`develop` with its own patch and `(#N)`. A squash of the feature would replace
them with one commit: a release could not take one sub-task fix and be seen to
have it, and the sub-task PR numbers would be gone from `develop`.

## Jira

- A sub-task PR into `feature/**` moves its ticket to Code Review when it opens
  (`jira-pr-opened.yml`).
- When the feature PR merges into `develop`, `jira-update-on-merge.yml` reads
  the PP keys from the title, the branch and the subject line of every commit
  in the PR, and moves each one to QA/Review, as it does for a single PR.
  Commit bodies are not read, because they name related tickets that the change
  does not implement.
- Moving a ticket to Done stays a manual step after QA, as for a single PR.

## Not done

- A sub-task PR merging into the feature branch does not change its ticket.
- The commit list comes from the GitHub API, which returns at most 250 commits
  for one PR.
