# Releasing Palace iOS

This document describes the end-to-end release process for ios-core. The flow follows the same release-branch / point-release pattern used by Palace backend and Android, with full automation around Jira ticket tagging.

## TL;DR

1. **Cut a release branch** from develop: `git push origin develop:release/x.y.z`
2. **Cut an RC**: `gh workflow run release-rc.yml --ref release/x.y.z`
3. **QA tests** the prerelease against the auto-tagged Jira tickets
4. **Bug fix?** Bump Info.plist version on the release branch, re-run step 2
5. **Ship**: open PR `release/x.y.z` → `main`, merge it
6. **Back-merge**: PR `release/x.y.z` → `develop` to carry RC fixes forward

Everything else — release notes, GitHub releases, Jira fixVersions — is automated.

## Why a release branch

Cutting `release/x.y.z` from develop freezes the RC contents while develop keeps moving. QA gets a stable test target, bug fixes are isolated, and develop stays open for new work. This matches how Palace backend and Android operate.

## Step-by-step

### 1. Cut the release branch

From any clean checkout (or directly from the GitHub UI), branch from current develop:

```bash
git fetch origin
git push origin refs/remotes/origin/develop:refs/heads/release/2.2.5
```

The branch lives only on the remote — no local checkout needed.

### 2. Cut a release candidate

```bash
gh workflow run release-rc.yml --ref release/2.2.5
```

This dispatches `Palace Release Candidate`, which:

1. Generates clean release notes via the git-log-based `ReleaseNotes.py` (extracts every `PP-####` key from commit subjects + bodies in `LAST_TAG..HEAD`)
2. Deletes any existing prerelease with the same `VERSION_NUM` (refuses to clobber a non-prerelease shipping tag — that's the safety guard)
3. Creates a fresh GitHub **prerelease** tagged `VERSION_NUM`, targeting the release branch
4. Invokes `jira-release-sync.yml` as a reusable workflow in the same run
5. Creates Jira version `iOS x.y.z`, links the GitHub release URL, and stamps `fixVersions` on every PP ticket in the notes body

QA now has their test list automatically — no manual tagging.

### 3. Iterating on the RC (point releases)

If QA finds bugs:

1. Land the fix on `release/x.y.z` (direct commit or PR-to-release-branch)
2. Bump the Info.plist version on the release branch (e.g. `2.2.5` → `2.2.5.1`) — judgment call about point vs minor goes here, do it by hand
3. Re-run `gh workflow run release-rc.yml --ref release/x.y.z`
4. New prerelease created with the new version, Jira tagged with the new fixVersion (`iOS 2.2.5.1`)
5. Repeat until QA approves a build

The previous prerelease is automatically deleted when a new RC with the same `VERSION_NUM` is cut. Different versions coexist, so iterating doesn't lose history.

### 4. Shipping the final release

Once QA approves an RC:

1. Open a PR `release/x.y.z` → `main`, get review, merge
2. `release-on-merge.yml` (`Palace Release`) fires automatically:
   - Generates the same release notes
   - **Promotes** the existing prerelease (that's the RC QA validated) to a final release by clearing the `prerelease` flag and updating the title
   - Invokes `jira-release-sync.yml` as a reusable workflow — confirms/refreshes the Jira fixVersion stamping (idempotent; safe to re-run)
3. Open a PR `release/x.y.z` → `develop` to back-merge any RC bug fixes into the main development branch

The release branch can be deleted after both merges land.

## What's in the release notes

`ReleaseNotes.py` (lives in `mobile-certificates/Certificates/Palace/iOS/`) walks `git log $LAST_TAG..HEAD`, extracts every `PP-####` key from commit subjects and bodies, and groups them by ticket.

### Public vs internal output

Two verbosity levels intentionally show different content:

| Verbosity | Used by | Contents |
|---|---|---|
| `-v 2` | **Public GitHub release body** | Ticketed entries only (`[PP-XXXX] subject (PR#NNN)`) |
| `-v 3` | **Internal TestFlight changelog** | Ticketed + filtered "Other changes" (PR-merged unticketed work only) |

The public release body intentionally **does not include** internal/CI noise, security-adjacent commits (credential handling), workflow plumbing iterations, or unticketed direct commits. Anything user-facing enough for the public should have a Jira ticket — that's the forcing function.

### Untickted work is invisible to the public

If a PR ships without a `PP-####` key in any commit message, it will **not** appear in the public release notes. It will still appear in the internal TestFlight changelog so QA sees it, but end users won't.

To make unticketed work public, backfill a `PP-####` reference into a commit on the branch (or amend the merge commit subject) before cutting the next RC.

### Where things live

- **`.github/workflows/release-rc.yml`** — RC dispatch workflow (manual trigger, branched from `release/*`)
- **`.github/workflows/release-on-merge.yml`** — Final release workflow (auto-fires on PR-to-main close)
- **`.github/workflows/jira-release-sync.yml`** — Reusable workflow invoked by both above; also supports manual `workflow_dispatch` for emergencies
- **`scripts/create-release-notes.sh`** — Wrapper that sets up the venv and writes notes + TestFlight changelog
- **`mobile-certificates/Certificates/Palace/iOS/ReleaseNotes.py`** — The actual git-log-based notes generator

## Manual fallback

If the automation breaks for any reason, you can always re-run the Jira sync by hand against any existing tag:

```bash
gh workflow run jira-release-sync.yml -f tag=2.2.5
```

This is idempotent — Jira just confirms the version exists and re-stamps the fixVersions. Safe to run multiple times.

## Known gotchas

- **Workflow file changes on a release branch**: when cutting an RC, GitHub Actions uses the workflow file *from the dispatched ref*, not from main. If you patch a workflow on `release/x.y.z`, the patched version runs. Drift between main and release branches is possible — keep an eye out during long QA cycles.
- **Workflow_dispatch requires the file on the default branch**: `release-rc.yml` must exist on `main` for any branch to dispatch it. The file is added once via PR; subsequent edits can happen on release branches without re-PRing to main.
- **`workflow` PAT scope**: The CI PAT (`CI_GITHUB_ACCESS_TOKEN`) lacks `workflow` and admin scopes, which is why all release operations use the default `GITHUB_TOKEN` for `gh release create/edit/delete`. Downstream Jira sync runs as a reusable workflow in the same run context, sidestepping the "GITHUB_TOKEN events don't trigger workflows" rule entirely.
