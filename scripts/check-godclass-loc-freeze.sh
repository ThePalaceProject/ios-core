#!/bin/bash
# check-godclass-loc-freeze.sh
#
# WAVE 0 RATCHET (god-class decomposition campaign — see
# docs/architecture/god-class-decomposition-plan.md §2.4 / §4).
#
# The six target god-classes accreted ~+1,400 LOC in 19 days because every
# reliability fix lands *inside* the hub where the seams are. This gate freezes
# that: each target file's live line count may not EXCEED a checked-in baseline.
#
#   - EXCEEDS baseline  -> FAIL (the accretion this ratchet exists to stop).
#   - AT baseline       -> PASS.
#   - BELOW baseline    -> PASS, and prints the new lower number so a human can
#                          ratchet the baseline down (this script never rewrites
#                          the baseline — a ratchet only tightens by hand).
#
# Counts are read LIVE from the tree (wc -l), so no generated state to drift.
#
# Baseline file (checked in): scripts/godclass-loc-baseline.txt
#   Format, one file per line:   <loc><whitespace><repo-relative-path>
#   '#' comments and blank lines ignored.
#
# Usage:
#   check-godclass-loc-freeze.sh              # gate against the checked-in baseline
#   check-godclass-loc-freeze.sh --count      # print "<loc>\t<path>" for each
#                                             # baselined file and exit 0 (bootstrap)
#
# Env overrides (for tests):
#   GODCLASS_ROOT      repo root the paths are resolved against (default: script's ../..)
#   GODCLASS_BASELINE  baseline file (default: <root>/scripts/godclass-loc-baseline.txt)
#
# Exit: 0 = at/below baseline (PASS); 1 = a file exceeds baseline (FAIL); 2 = usage/error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${GODCLASS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASELINE="${GODCLASS_BASELINE:-$ROOT/scripts/godclass-loc-baseline.txt}"
MODE="${1:-}"

[ -f "$BASELINE" ] || { echo "[godclass-loc] ERROR: baseline not found: $BASELINE"; exit 2; }

loc_of() {  # live line count of a file, 0 if missing
  local p="$1"
  [ -f "$p" ] || { echo "-1"; return; }
  wc -l < "$p" | tr -d ' '
}

FAIL=0
DROPPED=0
RESULTS=""

while IFS= read -r raw; do
  # strip comments / blanks
  line="${raw%%#*}"
  # trim
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  base_loc="${line%%[[:space:]]*}"
  rel_path="${line#"$base_loc"}"
  rel_path="$(printf '%s' "$rel_path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$base_loc" in
    ''|*[!0-9]*) echo "[godclass-loc] ERROR: bad baseline line: $raw"; exit 2 ;;
  esac
  cur="$(loc_of "$ROOT/$rel_path")"

  if [ "$MODE" = "--count" ]; then
    printf '%s\t%s\n' "$cur" "$rel_path"
    continue
  fi

  if [ "$cur" = "-1" ]; then
    RESULTS="$RESULTS\nMISSING  $rel_path (baselined at $base_loc; file not found — was it moved/renamed? update baseline)"
    FAIL=1
  elif [ "$cur" -gt "$base_loc" ]; then
    RESULTS="$RESULTS\nGREW     $rel_path  $base_loc -> $cur  (+$((cur - base_loc)))  ← exceeds freeze"
    FAIL=1
  elif [ "$cur" -lt "$base_loc" ]; then
    RESULTS="$RESULTS\nshrank   $rel_path  $base_loc -> $cur  (ratchet baseline DOWN to $cur)"
    DROPPED=1
  else
    RESULTS="$RESULTS\nok       $rel_path  $cur"
  fi
done < "$BASELINE"

[ "$MODE" = "--count" ] && exit 0

if [ "$FAIL" -eq 1 ]; then
  echo "[godclass-loc] FAIL: a frozen god-class grew past its baseline."
  echo "  These files are frozen while the decomposition campaign runs (Wave 0 ratchet)."
  echo "  Land your fix by EXTRACTING into a collaborator/package, not by growing the hub."
  printf '%b\n' "$RESULTS"
  exit 1
fi

echo "[godclass-loc] PASS: no god-class exceeds its frozen baseline."
printf '%b\n' "$RESULTS"
[ "$DROPPED" -eq 1 ] && echo "[godclass-loc] NOTE: one or more files shrank — ratchet the baseline down (values above)."
exit 0
