---
name: release-merge-policy
type: evolving
status: active
created: 2026-05-26
last_refresh: 2026-05-26
freshness_window: 365d
owners: [general]
description: Release & Hotfix Merge Policy
---

# Release & Hotfix Merge Policy

**TL;DR:** Merges into `main` use regular merge commits (`--no-ff`). Squash-merge is forbidden on `main`-bound work because it destroys commit SHAs, which causes the next release-branch → main merge to hit catastrophic conflicts even when content is logically identical.

## The policy

| Source branch | Target | Merge type |
|---|---|---|
| `release/X.Y.Z` | `main` | `--merge` (no-ff) |
| `hotfix/X.Y.Z-*` | `main` | `--merge` (no-ff) |
| Hotfix forward-port branch | `develop` | `--merge` (no-ff) |
| Feature PR | `develop` | `--squash` is fine |

GitHub UI: use **"Create a merge commit"**. CLI: `gh pr merge <num> --merge`.

GitHub branch protection on `main` should restrict the merge-method allowlist to "Create a merge commit" only. Disable "Squash and merge" and "Rebase and merge" for this branch.

## Why squash-merge on main is harmful

Squash-merge replaces a branch's history (N commits, each with its own SHA) with a single new commit with a different SHA. From git's three-way-merge perspective, that new commit has no relationship to the originals — even though the *content* is identical.

This breaks the next release-branch merge in a specific, deterministic way:

1. A hotfix branch (`hotfix/3.0.2-a11y-launch`) is squash-merged into `main`. Original commits → discarded. One new commit on main with a new SHA.
2. The same hotfix content is forward-ported into `develop` (and from there into the next release branch, e.g. `release/3.1.0`) as the *original commits* — preserving their SHAs via cherry-pick or merge.
3. When `release/3.1.0` → `main` is attempted:
   - git looks for a merge base. The base is the last commit both branches share — which is BEFORE the squash.
   - git compares both sides to that base.
   - On main's side: 1 squash commit with a new SHA, modifying many files.
   - On release/3.1.0's side: the original N commits (different SHAs), modifying the same files.
   - git sees this as **two different branches modifying the same files**, not as "main has the same fix as release/3.1.0."
   - Result: conflict on every file the hotfix touched.

This is **identity loss**: the content is reconcilable, but the SHAs aren't.

## What happened to 3.1.0 (post-mortem)

The 3.1.0 release-branch merge into `main` hit **296 file conflicts**. Every one was a squash-merge identity-loss artifact, not real content divergence.

Trace:
- **PR #953** (3.0.2 hotfix — VoiceOver activation + library-selector multi-modal) was squash-merged into `main` on 2026-05-18. Originals SHAs → discarded.
- **PR #972** (3.0.3 hotfix — Marketplace LCP audiobook open) was squash-merged into `main` on 2026-05-20. Originals → discarded.
- Meanwhile, those same fixes had been forward-ported into `develop` (and then into `release/3.1.0`) via PR #954 and the equivalent for 3.0.3 — preserving the original commit identities.
- 2026-05-26: `release/3.1.0 → main` was attempted (PR #997). 296 files conflicted. Most were squash-merge artifacts; a handful were genuine cross-cycle changes.
- Auto-resolution with `git merge -X theirs` introduced its own noise: duplicated `PBXBuildFile` entries in `Palace.xcodeproj/project.pbxproj`, and `.specterqa/*` files were preserved on the merge result even though release/3.1.0 had deleted them as part of the simdrive cutover (PR #895).

### The fix that landed

PR #997 was closed. A new branch `release-3.1.0-final` was created off main, and a merge commit was built manually with `git commit-tree`:

```bash
git checkout -b release-3.1.0-final origin/main
TREE=$(git rev-parse origin/release/3.1.0^{tree})
COMMIT=$(echo "<message>" | git commit-tree "$TREE" -p origin/main -p origin/release/3.1.0)
git update-ref refs/heads/release-3.1.0-final "$COMMIT"
git reset --hard release-3.1.0-final
git push -u origin release-3.1.0-final   # required SKIP_PRE_PUSH_TESTS=1 — see below
```

The merge commit's tree is byte-identical to `origin/release/3.1.0^{tree}` (the regression-signed-off content); parents are `[main, release/3.1.0]`. PR #998 landed cleanly.

### Downstream damage

The squash-merge problem produced secondary failures even after the merge resolved:

- **Release-notes script attribution broken.** `mobile-certificates/Certificates/Palace/iOS/ReleaseNotes.py` walks PRs merged into main since the last release tag. With only PR #998 visible on main (the merge commit), every PP-* ticket it found in #998's body got attributed to #998's title. The auto-generated changelog listed 42 tickets — **31 of them had already shipped in 2.2.4 / 3.0.0 / 3.0.2 / 3.0.3** and were verified via Jira `fixVersion`.
- **Jira pollution narrowly avoided.** The `Jira Release Sync` workflow chain from `release-on-merge.yml` would have stamped `iOS 3.1.0` onto all 42 tickets, including the 31 already-shipped ones. The auto-chain did not fire on the 3.1.0 release-on-merge run (cause unclear; pre-existing bug?), so the bad data never reached Jira. The release body was manually corrected and `jira-release-sync.yml` was re-dispatched against the 11-ticket cleaned version.

If the auto-chain had fired, cleanup would have been ~30 Jira tickets needing a fixVersion removal.

## When you still need the recovery recipe

This policy prevents future cases. But the existing squash-merge commits on `main` are permanent — they're already part of main's history. Any release-branch you merge into main going forward will compare against those existing squash commits.

**Strategy:** As long as future hotfixes use `--merge`, the squash artifacts shrink as a percentage of main's history. Eventually `release/3.2.0` and later will have a clean base to merge from. Until then, expect *some* conflicts on the next release-branch merge if it touches files modified by the 3.0.2 or 3.0.3 squash commits.

If you hit the `git commit-tree` recovery scenario again, the recipe is:

```bash
# From main:
git checkout -b release-X.Y.Z-final origin/main

# Build the merge commit by hand
TREE=$(git rev-parse origin/release/X.Y.Z^{tree})
COMMIT=$(echo "Merge release/X.Y.Z → main for X.Y.Z release" | \
  git commit-tree "$TREE" -p origin/main -p origin/release/X.Y.Z)
git update-ref refs/heads/release-X.Y.Z-final "$COMMIT"
git reset --hard release-X.Y.Z-final

# Push — pre-push test gate needs bypass (release merges always exceed its 180s budget)
SKIP_PRE_PUSH_TESTS=1 git push -u origin release-X.Y.Z-final

# Open PR with --merge as the merge method
gh pr create --base main --head release-X.Y.Z-final --title "X.Y.Z release"
```

Verify before pushing:

```bash
# Tree must be byte-identical to the release branch
diff <(git rev-parse HEAD^{tree}) <(git rev-parse origin/release/X.Y.Z^{tree})

# Parents must be [main, release/X.Y.Z]
git log -1 --format='%P'

# Diff vs release branch must be empty
git diff HEAD origin/release/X.Y.Z
```

## Implementation checklist

- [ ] **Repo settings → Branches → main protection rule:** restrict merge methods to "Create a merge commit" only.
- [ ] **Release runbook / CLAUDE.md:** policy documented (this doc + the section in `CLAUDE.md`).
- [ ] **`mobile-certificates/Certificates/Palace/iOS/ReleaseNotes.py`:** improve to walk merge-commit second-parent history so ticket attribution survives even when older squash commits exist in main. Separate ticket; not blocking on this doc.
- [ ] **Going forward:** when merging hotfix or release PRs into main, use the GitHub UI's "Create a merge commit" option. If using CLI, `gh pr merge <num> --merge`.

## Related

- [Forward-port discipline (memory: `feedback_hotfix_then_port.md`)](https://github.com/ThePalaceProject/ios-core/blob/develop/) — hotfixes are merged to main first, then forward-ported to develop. This policy preserves identity through that loop so the next release branch absorbs everything cleanly.
- The fact that release/3.1.0's tree was a strict superset of main's intended content (modulo squash-merge SHAs) is *only* true because of disciplined forward-port. Without it, tree-from-theirs would not be safe.
