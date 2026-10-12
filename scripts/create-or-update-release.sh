#!/usr/bin/env bash
#
# Publish the release for a version: create it, or update the notes on the one
# that is already there. Used by the release workflows, which previously each
# carried their own copy of this logic.
#
# Re-running a version is normal — a hotfix ships a new build number under an
# unchanged marketing version, so the release already exists and only its notes
# need refreshing. Which branch to take therefore has to be decided from the
# API, and gh-release-exists.sh is what decides it: it distinguishes "no release
# yet" from "the API did not answer" and refuses to answer on the latter.
#
# prior-art-checked: dependency-free shared-repo CI tooling, called from
# .github/workflows; the local tooling has no equivalent.
#
# Usage: create-or-update-release.sh <version> <notes-file>
set -euo pipefail

VERSION="${1:?usage: create-or-update-release.sh <version> <notes-file>}"
NOTES="${2:?usage: create-or-update-release.sh <version> <notes-file>}"

if [ ! -f "$NOTES" ]; then
  echo "create-or-update-release: release notes file not found: $NOTES" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# No `|| true` and no subshell swallowing: an indeterminate probe must stop the
# release, not fall through to one of the two branches.
state="$("$HERE/gh-release-exists.sh" "$VERSION")"

case "$state" in
  exists)
    echo "Release $VERSION already exists — updating its notes."
    gh release edit "$VERSION" --title "$VERSION" --notes-file "$NOTES"
    ;;
  absent)
    echo "No release for $VERSION yet — creating it."
    gh release create "$VERSION" --title "$VERSION" --notes-file "$NOTES"
    ;;
  *)
    echo "create-or-update-release: unexpected probe result '$state'" >&2
    exit 1
    ;;
esac
