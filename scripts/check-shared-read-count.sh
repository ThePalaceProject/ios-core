#!/bin/bash
# check-shared-read-count.sh
#
# WAVE 0 RATCHET (god-class decomposition campaign — see
# docs/architecture/god-class-decomposition-plan.md §2.4 / §3c / §4).
#
# `.shared` singleton reads are the coupling substrate the campaign is dissolving
# (every one becomes an AppContainer-injected seam). This gate freezes the count
# at a checked-in baseline and only ever lets it go DOWN (monotone-down):
#
#   - count >  baseline  -> FAIL  (a new ambient `.shared` reach was added).
#   - count == baseline  -> PASS.
#   - count <  baseline  -> PASS, prints the new lower number to ratchet down to.
#
# What is counted: occurrences of `<UpperCamelType>.shared` in Palace/*.swift,
# EXCLUDING:
#   - matches inside COMMENTS — `//`/`///` line comments (trailing or full-line) and
#     block-comment lines (`/* … * … */`). A `.shared` mention in a doc comment is
#     documentation, not a coupling edge; counting it penalizes accurate comments and
#     produced repeated false-positive freezes during the decomposition. (Residual: a
#     `.shared` on the SAME line after code but inside a trailing `/* … */` block, or a
#     non-`*`-aligned block-comment continuation line, is still counted — rare.)
#   - anything under Palace/Packages/ (SPM packages — already the target shape),
#   - the platform/system singletons listed in SYS_EXCLUDE below (UIApplication,
#     URLSession, URLCache, HTTPCookieStorage, FileManager, NotificationCenter,
#     Bundle, … — these are Apple-owned shims, out of scope by design, §3c row
#     "UIApplication.shared" / triad platform-shim exemption).
#
# Baseline file (checked in): scripts/godclass-shared-read-baseline.txt
#   Contents: a single integer (first non-comment line). '#' comments allowed.
#
# Usage:
#   check-shared-read-count.sh            # gate against baseline
#   check-shared-read-count.sh --count    # print the current count and exit 0 (bootstrap)
#
# Env overrides (for tests):
#   SHARED_SCAN_ROOT   directory to scan (default: <repo>/Palace)
#   SHARED_BASELINE    baseline file (default: <repo>/scripts/godclass-shared-read-baseline.txt)
#
# Exit: 0 = at/below baseline (PASS); 1 = above (FAIL); 2 = usage/error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SCAN_ROOT="${SHARED_SCAN_ROOT:-$REPO/Palace}"
BASELINE="${SHARED_BASELINE:-$REPO/scripts/godclass-shared-read-baseline.txt}"
MODE="${1:-}"

# Platform/system singletons that are exempt (Apple-owned; not campaign targets).
# Anchored to the start of the "<Type>.shared" match.
SYS_EXCLUDE='^(UIApplication|URLSession|URLCache|HTTPCookieStorage|FileManager|NotificationCenter|Bundle|ProcessInfo|UNUserNotificationCenter|BGTaskScheduler|XCTestObservationCenter|UIScreen|UIDevice|UIAccessibility|UIPasteboard|NSUbiquitousKeyValueStore|FileHandle|UIMenuSystem|UIFont)\.shared'

[ -d "$SCAN_ROOT" ] || { echo "[shared-read] ERROR: scan root not found: $SCAN_ROOT"; exit 2; }

# Strip Swift comments so a `.shared` mention in a comment isn't counted as a read:
#   1. drop block-comment lines (trimmed line starts with `*`, `*/`, or `/*`),
#   2. strip trailing/full `//` line comments — only when `//` is at line-start or
#      preceded by whitespace, so `://` inside a string URL is preserved.
# `//` is unambiguously a comment in Swift (there is no `//` operator), so this never
# strips real code. Line-oriented, so it is safe over cat-concatenated files.
strip_comments() {
  awk '{ s=$0; sub(/^[[:space:]]+/,"",s); if (s ~ "^/?[*]") next; print }' \
    | sed -E 's#(^|[[:space:]])//.*$#\1#'
}

# Concatenate all non-Packages Swift files, strip comments, then count occurrences.
shared_reads() {
  find "$SCAN_ROOT" -type f -name '*.swift' -not -path '*/Packages/*' -print0 2>/dev/null \
    | xargs -0 cat 2>/dev/null \
    | strip_comments \
    | grep -oE '[A-Z][A-Za-z0-9_]*\.shared' \
    | grep -vE "$SYS_EXCLUDE"
}

count_shared() {
  shared_reads | wc -l | tr -d ' '
}

CUR="$(count_shared)"

if [ "$MODE" = "--count" ]; then
  echo "$CUR"
  exit 0
fi

[ -f "$BASELINE" ] || { echo "[shared-read] ERROR: baseline not found: $BASELINE"; exit 2; }
BASE="$(grep -vE '^[[:space:]]*#' "$BASELINE" | grep -oE '[0-9]+' | head -1 || true)"
case "$BASE" in
  ''|*[!0-9]*) echo "[shared-read] ERROR: baseline file has no integer: $BASELINE"; exit 2 ;;
esac

if [ "$CUR" -gt "$BASE" ]; then
  echo "[shared-read] FAIL: non-system \`.shared\` reads went UP: $BASE -> $CUR (+$((CUR - BASE)))."
  echo "  This ratchet is monotone-down. Inject the dependency via an AppContainer seam"
  echo "  instead of reaching for \`.shared\` (see decomposition plan §3c)."
  echo "  Reads by type (sample, comments excluded):"
  shared_reads | sort | uniq -c | sort -rn | head -15
  exit 1
fi

if [ "$CUR" -lt "$BASE" ]; then
  echo "[shared-read] PASS: \`.shared\` reads DROPPED $BASE -> $CUR. Ratchet baseline down to $CUR."
  exit 0
fi

echo "[shared-read] PASS: non-system \`.shared\` reads at baseline ($CUR)."
exit 0
