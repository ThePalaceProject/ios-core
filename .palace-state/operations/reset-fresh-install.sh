#!/usr/bin/env bash
# .palace-state/operations/reset-fresh-install.sh
#
# Resets Palace on the target simulator to a deterministic fresh-install state:
#   1. Terminate any running Palace
#   2. Uninstall Palace
#   3. Pre-grant notifications + location permissions (avoids first-launch alerts
#      racing with subsequent automated taps)
#   4. Install Palace.app
#   5. Launch (unless --no-launch)
#
# Required env or args:
#   PALACE_STATE_SIM_UDID  — sim UDID to target (or --sim <udid>)
#   PALACE_STATE_APP_PATH  — Palace.app path (or --app <path>)
#
# Optional:
#   --no-launch            — install only; don't launch the app
#   --bundle-id <id>       — override (default: org.thepalaceproject.palace)
#
# Exit codes:
#   0  fresh-install state established
#   1  environment problem (sim not booted, app not found, simctl missing)
#   2  install or launch failed
#   3  invalid arguments
#
# Why pre-grant permissions:
#   The notifications + location alerts on first launch block coordinate-based
#   automated taps. Pre-granting via simctl privacy lets us land on a clean
#   "Add Library" screen with no overlaid dialogs — a deterministic step 0.

set -uo pipefail

BUNDLE_ID="${PALACE_STATE_BUNDLE_ID:-org.thepalaceproject.palace}"
SIM_UDID="${PALACE_STATE_SIM_UDID:-}"
APP_PATH="${PALACE_STATE_APP_PATH:-}"
LAUNCH=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) SIM_UDID="$2"; shift 2 ;;
    --app) APP_PATH="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --no-launch) LAUNCH=false; shift ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed -n 's/^# *//p'
      exit 0
      ;;
    *) echo "reset-fresh-install: unknown arg: $1" >&2; exit 3 ;;
  esac
done

if [[ -z "$SIM_UDID" ]]; then
  echo "reset-fresh-install: missing sim UDID (set PALACE_STATE_SIM_UDID or pass --sim)" >&2
  exit 3
fi

if [[ -z "$APP_PATH" ]]; then
  echo "reset-fresh-install: missing app path (set PALACE_STATE_APP_PATH or pass --app)" >&2
  exit 3
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "reset-fresh-install: app path does not exist: $APP_PATH" >&2
  exit 1
fi

# Check the sim is booted. We do NOT auto-boot — the caller is responsible
# for that, so this script stays idempotent on a fresh CI runner vs a local
# session where the sim is already up.
if ! xcrun simctl list devices booted 2>/dev/null | grep -q "$SIM_UDID"; then
  echo "reset-fresh-install: sim $SIM_UDID is not booted. Boot it first:" >&2
  echo "  xcrun simctl boot $SIM_UDID" >&2
  exit 1
fi

echo "[reset-fresh-install] sim=$SIM_UDID bundle=$BUNDLE_ID app=$APP_PATH"

# 1. Terminate any running instance (ignore errors — nothing running is fine).
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

# 2. Uninstall (ignore errors — already absent is fine).
xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

# 3. Pre-grant permissions. Two that matter for Palace's first-launch path:
#    notifications (post-install push prompt) and location (some auth flows).
#    Grant is best-effort; on iOS 26+ simctl privacy syntax may shift.
xcrun simctl privacy "$SIM_UDID" grant notifications "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl privacy "$SIM_UDID" grant location "$BUNDLE_ID" 2>/dev/null || true

# 4. Install. This is the operation we hard-fail on.
if ! xcrun simctl install "$SIM_UDID" "$APP_PATH" 2>&1; then
  echo "reset-fresh-install: install failed" >&2
  exit 2
fi

# 5. Launch (unless --no-launch). Hard-fail if requested but launch denied.
if [[ "$LAUNCH" == "true" ]]; then
  if ! launch_out=$(xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" 2>&1); then
    echo "reset-fresh-install: launch failed" >&2
    echo "$launch_out" >&2
    echo "" >&2
    echo "Hint: 'request denied by SBMainWorkspace' typically means the app was" >&2
    echo "built with 'xcodebuild build-for-testing' (links a test runner) rather" >&2
    echo "than 'xcodebuild build'. Re-build without the -test argument." >&2
    exit 2
  fi
  # Brief settle so SpringBoard finishes its launch transitions before the
  # caller starts driving taps. 1.5s is empirically enough on iPhone 16/17 Pro
  # sims; doubled if PALACE_STATE_SETTLE_SECONDS is set.
  sleep "${PALACE_STATE_SETTLE_SECONDS:-1.5}"
fi

echo "[reset-fresh-install] OK — state ready"
