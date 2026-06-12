#!/bin/bash
# regression-ipad-on-mac.sh — the C-ipad-on-mac regression cell.
#
# Runs the "Designed for iPad" Palace build NATIVELY on this Apple-Silicon Mac
# (ProcessInfo.isiOSAppOnMac == true — the configuration that produces the WS-4
# Adobe RMSDK recursive_mutex-at-exit crash; it cannot be reproduced in a sim),
# brackets an interaction window, then harvests + classifies the crash reports
# the run leaves behind for the WS-4 signature. This is the automated form of
# docs/architecture/ws4-mac-validation-runbook.md CHECK 2.
#
# simdrive cannot drive a Mac-native app (HID injection differs natively), so the
# Path-A / Path-B interaction is operator-driven (or a future XCUITest-mac
# co-driver). The deterministic, automatable core — launch bracketing + crash
# harvest + WS-4 classification + findings emission — is what this script owns.
#
# Usage:
#   scripts/regression-ipad-on-mac.sh --prebuilt <Palace.app> [opts]
#   scripts/regression-ipad-on-mac.sh --build [opts]            # build here first
#
# Options:
#   --prebuilt <App.app>   use this Designed-for-iPad .app (skip build)
#   --build                build the Designed-for-iPad product in this worktree
#   --run-dir <dir>        artifact dir (default .regression-runs/ipad-on-mac-<ts>)
#   --mode manual|path-a|path-b   interaction mode (default manual)
#   --interaction-timeout N seconds to allow interaction before harvest (default 180)
#   --process <name>       crash-report process match (default Palace)
#   --bundle-id <id>       app bundle id (default org.thepalaceproject.palace)
#   --first-seen-commit <sha>  carried into the finding (default: git HEAD)
#   -h|--help
#
# Exit code:
#   0  — cell ran AND no WS-4 signature found (PASS), OR cell skipped (non-arm64)
#   1  — WS-4 signature found at exit (FAIL — regression; finding emitted)
#   2  — config error (no app, build failed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

PREBUILT=""
DO_BUILD=0
RUN_DIR=""
MODE="manual"
INTERACTION_TIMEOUT=180
PROCESS="Palace"
BUNDLE_ID="org.thepalaceproject.palace"
FIRST_SEEN_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '')"
DEVICE_CELL="C-ipad-on-mac"
AREA="audiobook-drm-exit"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prebuilt) PREBUILT="$2"; shift 2 ;;
    --build) DO_BUILD=1; shift ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --interaction-timeout) INTERACTION_TIMEOUT="$2"; shift 2 ;;
    --process) PROCESS="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --first-seen-commit) FIRST_SEEN_COMMIT="$2"; shift 2 ;;
    --area) AREA="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

ts="$(date +%Y%m%d-%H%M%S)"
[ -z "$RUN_DIR" ] && RUN_DIR=".regression-runs/ipad-on-mac-$ts"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/crashes" "$RUN_DIR/findings"
SCAN_LOG="$RUN_DIR/logs/ipad-on-mac-$ts.log"

log() { echo "$@" | tee -a "$SCAN_LOG"; }

log "=== C-ipad-on-mac cell ==="
log "run-dir: $RUN_DIR"
log "commit:  $FIRST_SEEN_COMMIT"

# 1. Arch gate (skip-with-warning per BUILD-PLAN — never a hard fail).
PREFLIGHT="$SCRIPT_DIR/regression_matrix_preflight.py"
if [ -x "$PREFLIGHT" ] || [ -f "$PREFLIGHT" ]; then
  status="$(python3 "$PREFLIGHT" --cell "$DEVICE_CELL" --json 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["cells"][0]["status"])' 2>/dev/null)"
  if [ "$status" = "skip" ]; then
    log "SKIP: preflight reports C-ipad-on-mac not ready on this host (non-arm64)."
    exit 0
  fi
fi

# 2. Resolve the app bundle.
if [ "$DO_BUILD" = "1" ]; then
  DD="$RUN_DIR/dd"
  log "Building Designed-for-iPad product (platform=macOS,variant=Designed for iPad)..."
  xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=macOS,variant=Designed for iPad' \
    -derivedDataPath "$DD" -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO >>"$SCAN_LOG" 2>&1
  if [ $? -ne 0 ]; then
    log "ERROR: build failed — see $SCAN_LOG"
    exit 2
  fi
  PREBUILT="$(/usr/bin/find "$DD/Build/Products" -maxdepth 2 -name 'Palace.app' -type d | head -1)"
fi

if [ -z "$PREBUILT" ] || [ ! -d "$PREBUILT" ]; then
  log "ERROR: no app bundle. Pass --prebuilt <Palace.app> or --build."
  exit 2
fi
log "app: $PREBUILT"

# 3. Bracket: record the launch instant; only crash reports newer than this count.
SINCE="$(python3 -c 'import time; print(time.time())')"
log "launch-since epoch: $SINCE"

# 4. Launch the app natively on macOS.
log "Launching Mac-native (isiOSAppOnMac path)..."
open "$PREBUILT" >>"$SCAN_LOG" 2>&1
sleep 3
if pgrep -f "$PROCESS" >/dev/null 2>&1; then
  log "launched: process '$PROCESS' is running."
else
  log "WARN: process '$PROCESS' not detected after launch (may be sandboxed/renamed)."
fi

# 5. Interaction window — drive Path A / Path B per the runbook.
cat >>"$SCAN_LOG" <<EOF
--- interaction protocol (ws4-mac-validation-runbook.md CHECK 2) ---
Path A (normal): read an Adobe-DRM EPUB page, then Cmd-Q.
Path B (forced): reopen the book, send app to BACKGROUND (the atexit installs
  at applicationDidEnterBackground because didUseAdobeDRMThisSession is set),
  then trigger FinalTerminationWatchdog / a forced exit() — NOT kill -9.
Assert (both): no recursive_mutex fault, no new Crashlytics 9a91840677.
EOF

case "$MODE" in
  manual)
    log "MODE=manual: drive the Adobe-DRM open → background → forced-exit per the"
    log "protocol above. Harvest runs after ${INTERACTION_TIMEOUT}s (or when the app exits)."
    waited=0
    while [ "$waited" -lt "$INTERACTION_TIMEOUT" ]; do
      pgrep -f "$PROCESS" >/dev/null 2>&1 || { log "app exited at ${waited}s"; break; }
      sleep 5; waited=$((waited+5))
    done
    ;;
  path-a)
    log "MODE=path-a: backgrounding then quitting via AppleScript (best-effort)."
    osascript -e "tell application \"$PROCESS\" to quit" >>"$SCAN_LOG" 2>&1 || true
    sleep 5
    ;;
  path-b)
    log "MODE=path-b: backgrounding via Finder activate, then forced exit."
    osascript -e 'tell application "Finder" to activate' >>"$SCAN_LOG" 2>&1 || true
    sleep 3
    # Forced exit that still runs atexit handlers: SIGTERM is caught by the app's
    # termination path; kill -9 would bypass atexit and prove nothing, so it is
    # NOT used. (True watchdog-exit fidelity needs the in-app trigger; documented.)
    pkill -TERM -f "$PROCESS" >>"$SCAN_LOG" 2>&1 || true
    sleep 3
    ;;
  *) log "Unknown --mode $MODE"; exit 2 ;;
esac

# 6 + 7. Harvest crash reports since launch, classify for WS-4, emit finding.
log "Harvesting crash reports since launch..."
python3 "$SCRIPT_DIR/regression_crash_harvest.py" \
  --process "$PROCESS" --since "$SINCE" \
  --device-cell "$DEVICE_CELL" --area "$AREA" \
  --run-dir "$RUN_DIR" --first-seen-commit "$FIRST_SEEN_COMMIT" \
  --scan-log "$SCAN_LOG" --json | tee "$RUN_DIR/logs/harvest-$ts.json"
HARVEST_RC=${PIPESTATUS[0]}

# Copy any matched crash reports into the run's crashes/ for evidence retention.
python3 - "$RUN_DIR/logs/harvest-$ts.json" "$RUN_DIR/crashes" <<'PY' >>"$SCAN_LOG" 2>&1 || true
import json, shutil, sys, pathlib
data = json.load(open(sys.argv[1])); dest = pathlib.Path(sys.argv[2])
for c in data.get("crashes", []):
    p = pathlib.Path(c["path"])
    if p.exists():
        shutil.copy2(p, dest / p.name)
PY

if [ "$HARVEST_RC" = "1" ]; then
  log "VERDICT: FAIL — WS-4 recursive_mutex signature present at exit. Finding emitted."
  exit 1
fi
log "VERDICT: PASS — no WS-4 signature; the _exit(0) remediation held this run."
exit 0
