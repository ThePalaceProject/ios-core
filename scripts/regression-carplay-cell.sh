#!/bin/bash
# regression-carplay-cell.sh — the C-carplay regression cell.
#
# CarPlay cannot be interactively driven on a simulator (separate scene/window,
# no public touch injection — see docs/regression/CARPLAY-FEASIBILITY.md). So
# this cell's regression signal is the HEADLESS PalaceTests/CarPlay XCTest suite,
# run on the baseline iPhone sim. Test failures become findings via
# regression_xcresult_findings.py (own shard, pinned schema).
#
# Usage:
#   scripts/regression-carplay-cell.sh [--sim-id <UDID>] [--run-dir <dir>]
#       [--classes "CarPlayTests,CarPlayAuthHelperReadinessTests,..."]
#       [--first-seen-commit <sha>]
#
# Exit code:
#   0  — cell ran; CarPlay suite all-green (PASS), OR cell skipped (preflight)
#   1  — at least one CarPlay test failed (findings emitted; FAIL)
#   2  — config / build error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

SIM_ID="${HARNESS_SESSION_SIM_UDID:-}"
RUN_DIR=""
CLASSES="CarPlayTests,CarPlayIntegrationTests,CarPlayOpenAppAlertTests,CarPlayLibraryRefreshTests,CarPlayNowPlayingTemplateTests,CarPlayChapterListTests,CarPlayPlaybackErrorTests,CarPlayAudiobookBridgePresenterMigrationTests,CarPlayAuthHelperReadinessTests"
FIRST_SEEN_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '')"
DEVICE_CELL="C-carplay"
AREA="carplay"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim-id) SIM_ID="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --classes) CLASSES="$2"; shift 2 ;;
    --first-seen-commit) FIRST_SEEN_COMMIT="$2"; shift 2 ;;
    --area) AREA="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

ts="$(date +%Y%m%d-%H%M%S)"
[ -z "$RUN_DIR" ] && RUN_DIR=".regression-runs/carplay-$ts"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/findings"
LOG="$RUN_DIR/logs/carplay-$ts.log"
XCRESULT="$RUN_DIR/logs/carplay-$ts.xcresult"

log() { echo "$@" | tee -a "$LOG"; }

log "=== C-carplay cell (headless XCTest) ==="
log "classes: $CLASSES"

# Resolve the destination from the preflight (C-iphone-26 base) if no sim given.
if [ -z "$SIM_ID" ]; then
  DEST="$(python3 "$SCRIPT_DIR/regression_matrix_preflight.py" --cell C-carplay --json 2>/dev/null \
          | python3 -c 'import json,sys; c=json.load(sys.stdin)["cells"][0]; print(c["destination"] if c["status"]=="ready" else "")' 2>/dev/null)"
  if [ -z "$DEST" ]; then
    log "SKIP: C-carplay base sim not ready (preflight)."
    exit 0
  fi
else
  DEST="platform=iOS Simulator,id=$SIM_ID"
fi
log "destination: $DEST"

# Build the -only-testing args from the class list.
ONLY=()
IFS=',' read -ra CLS <<< "$CLASSES"
for c in "${CLS[@]}"; do ONLY+=("-only-testing:PalaceTests/$c"); done

log "Running CarPlay suite..."
xcodebuild test \
  -project Palace.xcodeproj -scheme Palace \
  -destination "$DEST" \
  "${ONLY[@]}" \
  -resultBundlePath "$XCRESULT" \
  >>"$LOG" 2>&1
BUILD_RC=$?

if [ ! -d "$XCRESULT" ]; then
  log "ERROR: no result bundle produced (build/test setup failure, rc=$BUILD_RC) — see $LOG"
  exit 2
fi

# Parse failures → findings (own shard). Exit 1 if any failure.
python3 "$SCRIPT_DIR/regression_xcresult_findings.py" \
  --xcresult "$XCRESULT" \
  --device-cell "$DEVICE_CELL" --area "$AREA" \
  --run-dir "$RUN_DIR" --first-seen-commit "$FIRST_SEEN_COMMIT" \
  --json | tee "$RUN_DIR/logs/carplay-findings-$ts.json"
PARSE_RC=${PIPESTATUS[0]}

if [ "$PARSE_RC" = "1" ]; then
  log "VERDICT: FAIL — CarPlay regression(s) found. Findings emitted to $RUN_DIR/findings/."
  exit 1
fi
log "VERDICT: PASS — CarPlay headless suite all-green."
exit 0
