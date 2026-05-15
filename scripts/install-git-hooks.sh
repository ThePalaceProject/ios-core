#!/usr/bin/env bash
# install-git-hooks.sh — wire repo-local symlinks for git hooks.
#
# By default this installs only the hooks that are mandatory for the
# harness convention:
#   - commit-msg            → harness commit-msg-stanza enforcement
#   - pre-commit (disabled) → kept as-is (matches current state)
#
# Opt-in flags:
#   --with-pre-push-tests   symlink .git/hooks/pre-push to
#                           scripts/hooks/pre-push-test-gate.sh (Part B).
#                           OFF BY DEFAULT — the test gate is still
#                           opt-in until we've burned it in.
#
# Misc:
#   --dry-run               print what would happen, don't touch disk
#   -h | --help             this help
#
# This script is idempotent: re-running won't damage existing symlinks
# or back-up files. It refuses to overwrite a NON-symlink hook file
# (e.g. the stock LFS-installed pre-push) unless you pass --force.

set -uo pipefail

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOKS_DIR="$REPO_DIR/.git/hooks"
SCRIPT_HOOKS_DIR="$REPO_DIR/scripts/hooks"

DRY_RUN=0
FORCE=0
WITH_PRE_PUSH_TESTS=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-pre-push-tests) WITH_PRE_PUSH_TESTS=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    --force)               FORCE=1; shift ;;
    -h|--help)             usage 0 ;;
    *) echo "Unknown flag: $1" >&2; usage 1 ;;
  esac
done

if [[ ! -d "$HOOKS_DIR" ]]; then
  echo "ERROR: $HOOKS_DIR not found — is this a git repo?" >&2
  exit 1
fi
if [[ ! -d "$SCRIPT_HOOKS_DIR" ]]; then
  echo "ERROR: $SCRIPT_HOOKS_DIR not found — wrong cwd?" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# install_link target_in_hooks  source_in_scripts
# ---------------------------------------------------------------------------
install_link() {
  local target="$HOOKS_DIR/$1"
  local source="$SCRIPT_HOOKS_DIR/$2"

  if [[ ! -e "$source" ]]; then
    echo "  SKIP $1 — source $source missing" >&2
    return 1
  fi

  # Already pointing at the right place?
  if [[ -L "$target" ]]; then
    local current
    current="$(readlink "$target")"
    if [[ "$current" == "$source" ]]; then
      echo "  OK   $1 (already symlinked → $source)"
      return 0
    fi
    if [[ "$FORCE" -eq 0 ]]; then
      echo "  SKIP $1 (symlink points at $current — pass --force to relink)" >&2
      return 1
    fi
  fi

  # Existing non-symlink file blocks the install unless --force.
  if [[ -e "$target" && ! -L "$target" ]]; then
    if [[ "$FORCE" -eq 0 ]]; then
      echo "  SKIP $1 (regular file present — pass --force to back up + replace)" >&2
      return 1
    fi
    local backup="${target}.bak.$(date +%s)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "  DRY  mv $target $backup"
    else
      mv "$target" "$backup"
      echo "  BAK  $1 → $(basename "$backup")"
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  DRY  ln -sf $source $target"
  else
    ln -sf "$source" "$target"
    chmod +x "$source" 2>/dev/null || true
    echo "  LINK $1 → $source"
  fi
}

echo "=== install-git-hooks.sh ==="
echo "Repo: $REPO_DIR"
[[ "$DRY_RUN" -eq 1 ]] && echo "Mode: DRY RUN"
echo ""

# ---------------------------------------------------------------------------
# Mandatory hooks — keep the existing harness wiring intact. We do NOT
# touch .git/hooks/commit-msg if it's already correctly symlinked to
# the harness's commit-msg-stanza.sh. We do NOT touch pre-commit.disabled.
#
# Currently the only repo-tracked target the harness owns is commit-msg,
# and that's already wired by the harness installer (see CLAUDE.local.md).
# We leave it alone unless asked.
# ---------------------------------------------------------------------------
echo "Mandatory hooks: (no changes — managed by harness installer)"

# ---------------------------------------------------------------------------
# Opt-in: pre-push test gate
# ---------------------------------------------------------------------------
if [[ "$WITH_PRE_PUSH_TESTS" -eq 1 ]]; then
  echo ""
  echo "Opt-in: pre-push test gate (--with-pre-push-tests)"
  install_link "pre-push" "pre-push-test-gate.sh"
else
  echo ""
  echo "Opt-in: pre-push test gate is OFF. Enable with --with-pre-push-tests."
fi

echo ""
echo "Done. To verify:"
echo "  ls -la $HOOKS_DIR/commit-msg $HOOKS_DIR/pre-push 2>/dev/null"
