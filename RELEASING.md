# Releasing

How Palace iOS gets from a merged PR to TestFlight and the App Store. The
GitHub Actions workflows under [`.github/workflows/`](./.github/workflows/)
do most of the work; this doc explains the conventions humans need to
follow.

## Branching model

- **`develop`** — integration branch. All routine PRs target `develop`.
- **`main`** — release-only. Never open a PR directly against `main`; it
  receives merges from a `release/<version>` branch when a release goes out.
- **`release/<version>`** (for example `release/3.0.2`) — release branches
  cut from `develop` for stabilization. Hotfixes for an out-the-door version
  land here first and then get back-merged or forward-ported to `develop`.
- **`testflight/<topic>`** — short-lived branches for ad-hoc TestFlight
  cuts that aren't a tagged release (for example a build for a single
  reviewer to validate a bug). Commits on these branches use the
  `[testflight]` prefix.
- **`feat/<topic>`**, **`fix/<topic>`**, **`chore/<topic>`** — routine
  feature, bug-fix, and chore branches. PRs from these target `develop`.

## Commit prefixes

Recent history shows two release-line prefixes worth following:

- `[3.0.x]` (or whichever release line) for commits that belong to a
  specific release branch — typically version bumps, hotfixes, and CI
  guards.
- `[testflight]` for commits that exist only to ship a TestFlight build.

PR-based commits on `develop` follow whatever convention the PR title uses
(commonly `[ticket]: summary` or `Phase N: summary`).

## Version bump

Update `MARKETING_VERSION` in `Palace.xcodeproj/project.pbxproj`. The build
number is automated through the workflows below — manual bumps happen on
release branches and are usually a single-line edit accompanied by a
`[<version>] Bump MARKETING_VERSION X → Y` commit.

`scripts/ios-check-version.sh` runs in
[`upload.yml`](./.github/workflows/upload.yml) and
[`upload-on-merge.yml`](./.github/workflows/upload-on-merge.yml); it short-
circuits the workflow if the same build number already exists in
`ios-binaries`, so non-version-bumping merges don't produce TestFlight
builds.

## Release notes

The canonical script is `scripts/create-release-notes.sh`. It collects PR
titles, links, and Notion ticket references between the previous release
tag and `HEAD`.

The CI build delegates to `ReleaseNotes.py` from the
[`mobile-certificates`](https://github.com/ThePalaceProject/mobile-certificates)
repo (path: `Certificates/Palace/iOS/ReleaseNotes.py`). When invoking it
from a workflow, set `fetch-depth: 0` on the `actions/checkout` step so the
script can walk the full git history.

```bash
./scripts/create-release-notes.sh
```

## TestFlight upload

`scripts/testflight-upload.sh` exports the archive and runs `fastlane
deliver` against the App Store Connect API. The workflows
[`upload-on-merge.yml`](./.github/workflows/upload-on-merge.yml) (auto on
merge to `develop`) and [`upload.yml`](./.github/workflows/upload.yml)
(manual `workflow_dispatch`) are the standard entry points. Local
invocation is rare and requires the keychain and signing identity to be
populated by `xcode-settings.sh`.

## App Store

Two helpers exist for archive and export:

- `scripts/xcode-export-appstore.sh` — produces an App Store-signed `.ipa`
  from a built archive.
- `scripts/archive-and-upload-adhoc.sh` — archives and uploads an ad-hoc
  build (used for one-off device installs, not the App Store).

The release workflow ([`release-on-merge.yml`](./.github/workflows/release-on-merge.yml))
fires on merge to `main` and creates the GitHub release with generated
release notes; a manual variant is at
[`release.yml`](./.github/workflows/release.yml).

## Internal / agent workflow

Maintainers run `forge_release_check` (the ForgeOS gate-check) as
a release gate. ForgeOS verifies that all changesets on the release branch
have promoted gates before tagging. This is part of the agent workflow
described in [`CLAUDE.md`](./CLAUDE.md) and is enforced by local git hooks
on contributor machines. Outside contributors don't need to run ForgeOS;
the GitHub Actions workflows are the authoritative gate for everyone.
