#!/usr/bin/env bash
# .palace-state/restore.sh
#
# Restores Palace app data on the target sim from a named fixture captured
# previously via .palace-state/snapshot.sh. Sequence:
#   1. Verify fixture exists + metadata is readable
#   2. Confirm compatibility (warn on app_version mismatch; halt on
#      sim_device mismatch unless --no-strict)
#   3. Uninstall current Palace (clears existing data container)
#   4. Install fresh Palace.app
#   5. Restore Documents/ + Library/ from the tar into the new container
#   6. Launch
#
# Why steps 3-5 instead of "install once and overlay": iOS regenerates the
# data container UUID on every install, and the install must happen BEFORE
# we know the container path. Uninstall-then-install ensures we start from
# a known-empty container.
#
# Required:
#   PALACE_STATE_SIM_UDID  — sim UDID (or --sim <udid>)
#   PALACE_STATE_APP_PATH  — Palace.app path (or --app <path>)
#   Fixture name as positional arg.
#
# Optional:
#   --bundle-id <id>       — override (default: org.thepalaceproject.palace)
#   --no-launch            — install + restore data; don't launch
#   --no-strict            — warn on device mismatch instead of halting
#
# Exit codes:
#   0  state restored
#   1  environment problem
#   2  install / restore / launch failed
#   3  invalid arguments or fixture not found
#   4  fixture incompatible with current sim (use --no-strict to override)

set -uo pipefail

BUNDLE_ID="${PALACE_STATE_BUNDLE_ID:-org.thepalaceproject.palace}"
SIM_UDID="${PALACE_STATE_SIM_UDID:-}"
APP_PATH="${PALACE_STATE_APP_PATH:-}"
FIXTURE_NAME=""
LAUNCH=true
STRICT=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim)
      if [ -z "${2:-}" ]; then
        echo "restore: --sim requires an argument" >&2
        exit 3
      fi
      SIM_UDID="$2"
      shift 2
      ;;
    --app)
      if [ -z "${2:-}" ]; then
        echo "restore: --app requires an argument" >&2
        exit 3
      fi
      APP_PATH="$2"
      shift 2
      ;;
    --bundle-id)
      if [ -z "${2:-}" ]; then
        echo "restore: --bundle-id requires an argument" >&2
        exit 3
      fi
      BUNDLE_ID="$2"
      shift 2
      ;;
    --no-launch) LAUNCH=false; shift ;;
    --no-strict) STRICT=false; shift ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed -n 's/^# *//p'
      exit 0
      ;;
    -*) echo "restore: unknown flag: $1" >&2; exit 3 ;;
    *)
      if [[ -z "$FIXTURE_NAME" ]]; then
        FIXTURE_NAME="$1"; shift
      else
        echo "restore: unexpected positional arg: $1" >&2; exit 3
      fi
      ;;
  esac
done

if [[ -z "$SIM_UDID" || -z "$APP_PATH" || -z "$FIXTURE_NAME" ]]; then
  echo "restore: missing args. Need PALACE_STATE_SIM_UDID + PALACE_STATE_APP_PATH + fixture name" >&2
  exit 3
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="$REPO_ROOT/.palace-state/fixtures/$FIXTURE_NAME.tgz"
META="$REPO_ROOT/.palace-state/fixtures/$FIXTURE_NAME.meta.json"

if [[ ! -f "$ARCHIVE" ]]; then
  # Args were syntactically valid; the named fixture just doesn't exist on
  # this machine. That's an environment problem (run snapshot.sh first or
  # check the fixtures dir), not an arg-validation problem — exit 1.
  echo "restore: fixture not found: $ARCHIVE" >&2
  echo "Available fixtures:" >&2
  ls "$REPO_ROOT/.palace-state/fixtures/"*.tgz 2>/dev/null | xargs -n1 basename | sed 's/\.tgz$//' | sed 's/^/  /' >&2
  exit 1
fi

if [[ ! -f "$META" ]]; then
  echo "restore: metadata not found: $META" >&2
  exit 1
fi

# Compatibility checks. Use the same UDID-anchored regex as snapshot.sh so
# the captured/current device strings line up. Anchored on the 8-4-4-4-12
# hex-dash UDID shape — bare [A-F0-9-]+ would truncate "iPhone 17 Pro" at
# the "17".
DEVICE_INFO=$(xcrun simctl list devices 2>/dev/null | grep "$SIM_UDID" | head -1)
CURRENT_DEVICE=$(echo "$DEVICE_INFO" | sed -E 's/^[[:space:]]*//; s/ \([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\).*//')

# Extract metadata values via python (jq isn't guaranteed installed).
# Previously each field was read in its own python -c with 2>/dev/null, which
# meant a malformed/missing meta.json produced empty strings and silently
# bypassed the device-mismatch guard below (the `-n "$FIXTURE_DEVICE"` test
# would short-circuit). Read all three fields atomically and exit 4
# (fixture-incompat) on any parse failure.
META_PARSE=$(python3 -c "
import json, sys
meta = json.load(open('$META'))
print('{}|{}|{}|{}'.format(
    meta.get('fixture_format_version', ''),
    meta.get('sim_device', ''),
    meta.get('app_bundle_id', ''),
    meta.get('app_version', ''),
))
" 2>&1)
if [ $? -ne 0 ]; then
  echo "restore: failed to parse fixture metadata at $META" >&2
  echo "$META_PARSE" >&2
  echo "fixture metadata could not be parsed; aborting" >&2
  exit 4
fi
IFS='|' read -r FIXTURE_FORMAT_VERSION FIXTURE_DEVICE FIXTURE_BUNDLE FIXTURE_VERSION <<<"$META_PARSE"

# Forward-compat guard: this script understands fixture_format_version=1.
# A v2 fixture (e.g. one that ships keychain alongside the data container)
# would need new restore logic, so refuse rather than silently doing the
# wrong thing.
if [[ "$FIXTURE_FORMAT_VERSION" != "1" ]]; then
  echo "restore: unsupported fixture_format_version='$FIXTURE_FORMAT_VERSION' (expected '1')" >&2
  echo "This restore.sh supports v1 fixtures only. Re-snapshot or upgrade tooling." >&2
  exit 4
fi

if [[ -n "$FIXTURE_DEVICE" && "$FIXTURE_DEVICE" != "$CURRENT_DEVICE" ]]; then
  if [[ "$STRICT" == "true" ]]; then
    echo "restore: device mismatch — fixture was captured on '$FIXTURE_DEVICE', sim is '$CURRENT_DEVICE'" >&2
    echo "Pass --no-strict to restore anyway (UI coords may not align)." >&2
    exit 4
  else
    echo "[restore] WARNING: device mismatch (fixture='$FIXTURE_DEVICE', current='$CURRENT_DEVICE')" >&2
  fi
fi

if ! xcrun simctl list devices booted 2>/dev/null | grep -q "$SIM_UDID"; then
  echo "restore: sim $SIM_UDID not booted" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "restore: app path does not exist: $APP_PATH" >&2
  exit 1
fi

echo "[restore] fixture=$FIXTURE_NAME version=$FIXTURE_VERSION device=$FIXTURE_DEVICE"

# 1. Uninstall (always — guarantees a fresh container UUID)
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

# 2. Pre-grant + install
xcrun simctl privacy "$SIM_UDID" grant notifications "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl privacy "$SIM_UDID" grant location "$BUNDLE_ID" 2>/dev/null || true
if ! xcrun simctl install "$SIM_UDID" "$APP_PATH" 2>&1; then
  echo "restore: install failed" >&2
  exit 2
fi

# 3. Locate the new data container and untar the fixture into it
DATA_DIR=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null)
if [[ -z "$DATA_DIR" || ! -d "$DATA_DIR" ]]; then
  echo "restore: could not resolve data container after install" >&2
  exit 2
fi

# Wipe the data container before unpacking so we don't leave partial state
# behind from the install template. The snapshot captures all of Documents/
# and Library/ except Caches/, so anything outside that union has to go —
# the prior narrower cleanup left stray subdirs (e.g. Library/Cookies,
# Library/WebKit) that the snapshot never overwrites.
#
# Preserve Library/Caches/ to avoid re-downloading regenerable data after
# every restore, matching the asymmetry in snapshot.sh.
find "$DATA_DIR" -mindepth 1 -maxdepth 1 ! -name 'Library' -exec rm -rf {} + 2>/dev/null || true
if [[ -d "$DATA_DIR/Library" ]]; then
  find "$DATA_DIR/Library" -mindepth 1 -maxdepth 1 ! -name 'Caches' -exec rm -rf {} + 2>/dev/null || true
fi

if ! tar -xzf "$ARCHIVE" -C "$DATA_DIR" 2>&1; then
  echo "restore: tar extract failed" >&2
  exit 2
fi

# 4. Launch
if [[ "$LAUNCH" == "true" ]]; then
  if ! xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" 2>&1; then
    echo "restore: launch failed" >&2
    exit 2
  fi
  sleep "${PALACE_STATE_SETTLE_SECONDS:-1.5}"
fi

echo "[restore] OK — fixture $FIXTURE_NAME restored"
