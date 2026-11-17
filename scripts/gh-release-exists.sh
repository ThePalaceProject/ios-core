#!/usr/bin/env bash
#
# Report whether a GitHub release exists for a tag, with three outcomes rather
# than two.
#
#   stdout "exists"  exit 0  — a release is published for this tag
#   stdout "absent"  exit 0  — the API answered, and there is none
#                    exit 1  — the API did not answer; the caller must not guess
#
# Why this is not an inline `gh release view >/dev/null 2>&1`: that form collapses
# "no such release" and "the request did not complete" into one non-zero, and
# discards the message that tells them apart. A caller then takes its create
# branch for a version that is already released, and `gh release create` fails
# with "tag_name already exists" — precisely the case the probe exists to avoid.
# That took the 3.3.1 build-512 merge red on 2026-10-02, and left no evidence of
# the underlying error because stderr had gone to /dev/null.
#
# A transient error is retried, because one slow API call should not redden a
# release. An error that persists across attempts fails loudly, because a release
# decision made on an unknown is worse than a stopped pipeline.
#
# prior-art-checked: this is deliberately dependency-free so any contributor can
# run it unaided, and it is called from .github/workflows. Nothing in the local
# tooling applies — the nearest matches are a signed release-feed advisory and a
# governance changeset flow, neither of which answers "does this tag have a
# GitHub release".
#
# Usage: gh-release-exists.sh <tag> [attempts]
set -euo pipefail

TAG="${1:?usage: gh-release-exists.sh <tag> [attempts]}"
ATTEMPTS="${2:-3}"

err_file="$(mktemp)"
# shellcheck disable=SC2064  # expand err_file now, not at trap time
trap "rm -f '$err_file'" EXIT

attempt=1
while :; do
  if gh release view "$TAG" --json tagName >/dev/null 2>"$err_file"; then
    echo "exists"
    exit 0
  fi

  # `gh` says exactly "release not found" when the tag has no release. Match that
  # and nothing broader: a message we do not recognise is an unknown, not an absence.
  if grep -qi 'release not found' "$err_file"; then
    echo "absent"
    exit 0
  fi

  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    {
      echo "gh-release-exists: could not determine whether release '$TAG' exists."
      echo "Giving up after $ATTEMPTS attempt(s). Last error from 'gh release view':"
      sed 's/^/  /' "$err_file"
      echo "Not guessing: creating a release for a tag that already has one fails,"
      echo "and editing one that does not exist is equally wrong."
    } >&2
    exit 1
  fi

  sleep $(( attempt * 2 ))
  attempt=$(( attempt + 1 ))
done
