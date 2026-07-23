#!/bin/bash
# check-appcontainer-locator-count.sh
#
# WAVE 0 RATCHET (god-class decomposition campaign — see
# docs/architecture/god-class-decomposition-plan.md §2.4 / §3c gap 3 / §4).
#
# `AppContainer.production()` called OUTSIDE a composition root is a `.shared`
# read with extra steps: it preserves the ambient-reach graph and defeats
# testability exactly the same way (e.g. `AppContainer.production().accountsManager`
# in a default arg). The container is a composition root, not a service locator.
# This gate freezes the out-of-allowlist call-site count and only lets it go DOWN:
#
#   - count >  baseline  -> FAIL  (a new locator use was added).
#   - count == baseline  -> PASS.
#   - count <  baseline  -> PASS, prints the new lower number to ratchet down to.
#
# What is counted: occurrences of `AppContainer.production()` in Palace/*.swift,
# EXCLUDING:
#   - files whose repo-relative path matches an allowlist entry (composition roots:
#     AppContainer.swift itself, the app/scene delegates — see the allowlist file),
#   - lines that are an `@Environment` default (SwiftUI environment default value),
#   - anything under Palace/Packages/.
# (Test bootstrap under PalaceTests/ is out of scan scope entirely.)
#
# Allowlist file (checked in): scripts/godclass-appcontainer-locator-allowlist.txt
#   One path-suffix per line; a call site is exempt if its path CONTAINS the entry.
#   '#' comments and blank lines ignored.
#
# Baseline file (checked in): scripts/godclass-appcontainer-locator-baseline.txt
#   Contents: a single integer (first non-comment line).
#
# Usage:
#   check-appcontainer-locator-count.sh            # gate against baseline
#   check-appcontainer-locator-count.sh --count    # print current count, exit 0 (bootstrap)
#
# Env overrides (for tests):
#   LOCATOR_SCAN_ROOT   directory to scan (default: <repo>/Palace)
#   LOCATOR_BASELINE    baseline file (default: <repo>/scripts/godclass-appcontainer-locator-baseline.txt)
#   LOCATOR_ALLOWLIST   allowlist file (default: <repo>/scripts/godclass-appcontainer-locator-allowlist.txt)
#
# Exit: 0 = at/below baseline (PASS); 1 = above (FAIL); 2 = usage/error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SCAN_ROOT="${LOCATOR_SCAN_ROOT:-$REPO/Palace}"
BASELINE="${LOCATOR_BASELINE:-$REPO/scripts/godclass-appcontainer-locator-baseline.txt}"
ALLOWLIST="${LOCATOR_ALLOWLIST:-$REPO/scripts/godclass-appcontainer-locator-allowlist.txt}"
MODE="${1:-}"

[ -d "$SCAN_ROOT" ] || { echo "[locator] ERROR: scan root not found: $SCAN_ROOT"; exit 2; }

path_allowlisted() {  # 0 (true) if $1 contains any allowlist entry
  local path="$1"
  [ -f "$ALLOWLIST" ] || return 1
  local entry
  while IFS= read -r entry; do
    entry="${entry%%#*}"
    entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$entry" ] && continue
    case "$path" in *"$entry"*) return 0 ;; esac
  done < "$ALLOWLIST"
  return 1
}

# Emit each matching "path:line" then filter allowlisted files + @Environment lines.
count_locator() {
  local total=0 file
  while IFS= read -r file; do
    path_allowlisted "$file" && continue
    # occurrences in this file that are NOT @Environment defaults
    local c
    c="$(grep -nE 'AppContainer\.production\(\)' "$file" 2>/dev/null \
          | grep -vE '@Environment' \
          | grep -oE 'AppContainer\.production\(\)' | wc -l | tr -d ' ')"
    total=$((total + c))
  done < <(grep -rlE 'AppContainer\.production\(\)' "$SCAN_ROOT" --include='*.swift' --exclude-dir='Packages' 2>/dev/null)
  echo "$total"
}

# List offending files (for FAIL output).
list_locator() {
  local file c
  while IFS= read -r file; do
    path_allowlisted "$file" && continue
    c="$(grep -nE 'AppContainer\.production\(\)' "$file" 2>/dev/null | grep -vE '@Environment' | grep -cE 'AppContainer\.production\(\)' || true)"
    [ "${c:-0}" -gt 0 ] && printf '%4d  %s\n' "$c" "$file"
  done < <(grep -rlE 'AppContainer\.production\(\)' "$SCAN_ROOT" --include='*.swift' --exclude-dir='Packages' 2>/dev/null) | sort -rn
}

CUR="$(count_locator)"

if [ "$MODE" = "--count" ]; then
  echo "$CUR"
  exit 0
fi

[ -f "$BASELINE" ] || { echo "[locator] ERROR: baseline not found: $BASELINE"; exit 2; }
BASE="$(grep -vE '^[[:space:]]*#' "$BASELINE" | grep -oE '[0-9]+' | head -1 || true)"
case "$BASE" in
  ''|*[!0-9]*) echo "[locator] ERROR: baseline file has no integer: $BASELINE"; exit 2 ;;
esac

if [ "$CUR" -gt "$BASE" ]; then
  echo "[locator] FAIL: out-of-allowlist \`AppContainer.production()\` uses went UP: $BASE -> $CUR (+$((CUR - BASE)))."
  echo "  The container is a composition root, not a service locator. Inject the dependency"
  echo "  through the constructor instead (see decomposition plan §3c gap 3)."
  echo "  Top offending files:"
  list_locator | head -15
  exit 1
fi

if [ "$CUR" -lt "$BASE" ]; then
  echo "[locator] PASS: locator uses DROPPED $BASE -> $CUR. Ratchet baseline down to $CUR."
  exit 0
fi

echo "[locator] PASS: out-of-allowlist \`AppContainer.production()\` uses at baseline ($CUR)."
exit 0
