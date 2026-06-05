#!/usr/bin/env bash
# pre-commit-phase35-detectors.sh
#
# Phase 3.5 class-scan detectors (swarm_162a3219). Runs the 6 detectors
# against the staged diff; block-mode classes fail the commit, warn-mode
# classes just print to stderr.
#
# Bypass: SKIP_PHASE35_DETECTORS=1 (intentional carve-out; audit trail).
# Per-detector bypass: SKIP_PHASE35_<DETECTOR_ID>=1
#   (e.g. SKIP_PHASE35_FOREIGN_HOST_401_SCOPING=1)

set -eu

INPUT=$(cat || true)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
case "$COMMAND" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

if [ "${SKIP_PHASE35_DETECTORS:-0}" = "1" ]; then
  echo "[phase35-detectors] bypass active (SKIP_PHASE35_DETECTORS=1)" >&2
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ ! -f "$REPO_ROOT/CLAUDE.md" ] || [ ! -d "$REPO_ROOT/Palace" ]; then
  exit 0
fi

DIFF_FILE=$(mktemp -t phase35-diff.XXXX)
git -C "$REPO_ROOT" diff --cached > "$DIFF_FILE" 2>/dev/null || true
if [ ! -s "$DIFF_FILE" ]; then
  rm -f "$DIFF_FILE"
  exit 0
fi

# (id|script-basename|severity)  severity: block | warn
DETECTORS=(
  "FOREIGN_HOST_401_SCOPING|check-foreign-host-401-scoping.py|block"
  "LCP_ACQUISITION_RECURSIVE|check-lcp-acquisition-recursive.py|block"
  "COMPLETION_NIL_ERROR_SUPPRESSION|check-completion-nil-error-suppression.py|block"
  "NSERROR_PROBLEMDOC_PRESERVATION|check-nserror-problemdoc-preservation.py|block"
  "SWIFTUI_PLACEHOLDER_A11Y|check-swiftui-placeholder-a11y.py|warn"
  "NOTIFICATION_CENTER_OBSERVER_STORAGE|check-notification-center-observer-storage.py|warn"
)

OVERALL_EXIT=0

for entry in "${DETECTORS[@]}"; do
  IFS="|" read -r ID SCRIPT SEVERITY <<< "$entry"
  SCRIPT_PATH="$REPO_ROOT/scripts/$SCRIPT"
  [ ! -f "$SCRIPT_PATH" ] && continue

  BYPASS_VAR="SKIP_PHASE35_${ID}"
  if [ "${!BYPASS_VAR:-0}" = "1" ]; then
    echo "[phase35-detectors:$ID] bypass active ($BYPASS_VAR=1)" >&2
    continue
  fi

  # Capture exit BEFORE the `|| EXIT=$?` short-circuit. With `set -eu` enabled
  # we still need to handle non-zero exits without killing the script, but
  # `OUT=$(... || true)` was the bug — `$?` then captured the always-0 exit
  # of `|| true`. The correct shape captures the python exit via
  # `&& EXIT=0 || EXIT=$?`. Wall-failure 2026-06-05-swarm162a3219-arch1.md.
  OUT=$(python3 "$SCRIPT_PATH" --diff "$DIFF_FILE" --quiet 2>&1) && EXIT=0 || EXIT=$?

  if [ "$EXIT" -ne 0 ]; then
    if [ "$SEVERITY" = "block" ]; then
      echo "[phase35-detectors:$ID] BLOCK — staged diff contains class-detectable findings:" >&2
      echo "$OUT" >&2
      echo "  Bypass for this detector: $BYPASS_VAR=1 git commit ..." >&2
      OVERALL_EXIT=2
    else
      echo "[phase35-detectors:$ID] WARN — non-blocking findings:" >&2
      echo "$OUT" >&2
    fi
  fi
done

rm -f "$DIFF_FILE"
exit "$OVERALL_EXIT"
