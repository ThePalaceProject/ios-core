#!/bin/bash

# SUMMARY
#   Remove the private DRM submodules, then fetch every remaining submodule
#   anonymously over HTTPS. The noDRM build must not need a credential: it runs
#   on pull requests from forks, which get no repository secrets.
#
# USAGE
#   Run from the root of ios-core. Called by scripts/setup-repo-nodrm.sh.
#
# EXIT STATUS
#   Non-zero, naming the submodule and its URL, when a submodule cannot be
#   fetched without credentials.
#
# prior-art-checked: a public repository script; no harness capability applies.

set -euo pipefail

# Private repositories. The noDRM target does not build them; an anonymous
# fetch of any of them fails.
PRIVATE_SUBMODULES=(adept-ios adobe-content-filter ios-drm-audioengine ios-audiobook-overdrive)

# Each step is guarded so a second run is silent: `git submodule deinit`
# returns 0 on a missing submodule, but `git rm -rf` returns 128.
for path in "${PRIVATE_SUBMODULES[@]}"; do
  if [ -e "$path" ] || git submodule status "$path" >/dev/null 2>&1; then
    git submodule deinit -f "$path" 2>/dev/null || true
    git rm -rf "$path" 2>/dev/null || true
  fi
done

[ -f .gitmodules ] || exit 0

# .gitmodules uses `git@github.com:` URLs, and a CI runner has no SSH key.
# The empty credential.helper drops any helper from the user config, and
# GIT_TERMINAL_PROMPT=0 makes a credential request fail instead of waiting,
# so a submodule that is not public fails here on every machine.
anonymous_git() {
  GIT_TERMINAL_PROMPT=0 git \
    -c credential.helper= \
    -c url.https://github.com/.insteadOf=git@github.com: \
    "$@"
}

while read -r key path; do
  name="${key#submodule.}"
  name="${name%.path}"
  url="$(git config -f .gitmodules --get "submodule.$name.url")"
  if ! anonymous_git submodule update --init --recursive -- "$path"; then
    https_url="${url/#git@github.com:/https://github.com/}"
    echo "$0: could not fetch submodule $path from $https_url without credentials." 1>&2
    echo "$0: the noDRM build needs it; it must be a public repository." 1>&2
    exit 1
  fi
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
