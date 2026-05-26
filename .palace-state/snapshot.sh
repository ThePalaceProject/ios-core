#!/usr/bin/env bash
# .palace-state/snapshot.sh
#
# Captures the current Palace app data state on the target sim as a named
# fixture under .palace-state/fixtures/<name>.tgz + <name>.meta.json. The
# fixture can later be restored via .palace-state/restore.sh <name>.
#
# What's captured:
#   - Documents/   (Palace user data: bookmarks, settings, account list)
#   - Library/     (excluding Caches/ — those are regenerable noise)
#
# What's NOT captured (known gaps for v1):
#   - Keychain     (sim-wide, shared across apps — restoring requires
#                   matching sim+app+keychain access group)
#   - Downloaded books (excluded via tar — too large to ship in fixtures;
#                       restored state has clean download library)
#
# Required:
#   PALACE_STATE_SIM_UDID  — sim UDID (or --sim <udid>)
#   Fixture name as positional arg.
#
# Optional:
#   --bundle-id <id>       — override (default: org.thepalaceproject.palace)
#   --include-books        — include Documents/Books in the snapshot (rare)
#
# Exit codes:
#   0  fixture captured
#   1  environment problem (sim not booted, app not installed)
#   2  capture failed
#   3  invalid arguments

set -uo pipefail

BUNDLE_ID="${PALACE_STATE_BUNDLE_ID:-org.thepalaceproject.palace}"
SIM_UDID="${PALACE_STATE_SIM_UDID:-}"
FIXTURE_NAME=""
INCLUDE_BOOKS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim)
      if [ -z "${2:-}" ]; then
        echo "snapshot: --sim requires an argument" >&2
        exit 3
      fi
      SIM_UDID="$2"
      shift 2
      ;;
    --bundle-id)
      if [ -z "${2:-}" ]; then
        echo "snapshot: --bundle-id requires an argument" >&2
        exit 3
      fi
      BUNDLE_ID="$2"
      shift 2
      ;;
    --include-books) INCLUDE_BOOKS=true; shift ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed -n 's/^# *//p'
      exit 0
      ;;
    -*) echo "snapshot: unknown flag: $1" >&2; exit 3 ;;
    *)
      if [[ -z "$FIXTURE_NAME" ]]; then
        FIXTURE_NAME="$1"; shift
      else
        echo "snapshot: unexpected positional arg: $1" >&2; exit 3
      fi
      ;;
  esac
done

if [[ -z "$SIM_UDID" ]]; then
  echo "snapshot: missing sim UDID (set PALACE_STATE_SIM_UDID or pass --sim)" >&2
  exit 3
fi

if [[ -z "$FIXTURE_NAME" ]]; then
  echo "snapshot: missing fixture name (positional arg)" >&2
  exit 3
fi

# Validate fixture name — keep it filesystem-safe and human-readable
if [[ ! "$FIXTURE_NAME" =~ ^[a-z0-9._-]+$ ]]; then
  echo "snapshot: fixture name must match [a-z0-9._-]+ (got: $FIXTURE_NAME)" >&2
  exit 3
fi

if ! xcrun simctl list devices booted 2>/dev/null | grep -q "$SIM_UDID"; then
  echo "snapshot: sim $SIM_UDID is not booted" >&2
  exit 1
fi

# Resolve the app data container — fails if app isn't installed
DATA_DIR=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null)
if [[ -z "$DATA_DIR" || ! -d "$DATA_DIR" ]]; then
  echo "snapshot: $BUNDLE_ID is not installed on $SIM_UDID" >&2
  exit 1
fi

# Detect device info for the metadata file. simctl emits lines like:
#   "    iPhone 17 Pro (6C396179-608C-...) (Booted)"
# Strip leading whitespace, then strip " (UDID)" onward. Anchor the UDID
# match on the exact 8-4-4-4-12 hex-dash shape so we don't truncate
# "iPhone 17 Pro" at the "17" (which would otherwise match [A-F0-9-]+).
DEVICE_INFO=$(xcrun simctl list devices 2>/dev/null | grep "$SIM_UDID" | head -1)
DEVICE_NAME=$(echo "$DEVICE_INFO" | sed -E 's/^[[:space:]]*//; s/ \([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\).*//')

# App version
APP_BUNDLE_DIR=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" app 2>/dev/null)
APP_VERSION=""
if [[ -f "$APP_BUNDLE_DIR/Info.plist" ]]; then
  APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE_DIR/Info.plist" 2>/dev/null || echo "")
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/.palace-state/fixtures"
mkdir -p "$FIXTURES_DIR"

ARCHIVE="$FIXTURES_DIR/$FIXTURE_NAME.tgz"
META="$FIXTURES_DIR/$FIXTURE_NAME.meta.json"

# Build tar exclude list — Caches always; Books unless --include-books
EXCLUDES=(--exclude='Library/Caches')
if [[ "$INCLUDE_BOOKS" != "true" ]]; then
  EXCLUDES+=(--exclude='Documents/Books')
  EXCLUDES+=(--exclude='Documents/audiobooks')
fi

echo "[snapshot] capturing $BUNDLE_ID data on $SIM_UDID → $FIXTURE_NAME.tgz"
echo "[snapshot] source: $DATA_DIR"

if ! tar -czf "$ARCHIVE" -C "$DATA_DIR" "${EXCLUDES[@]}" Documents Library 2>&1; then
  echo "snapshot: tar capture failed" >&2
  exit 2
fi

# Build the excludes JSON array based on what tar actually skipped.
if [[ "$INCLUDE_BOOKS" == "true" ]]; then
  EXCLUDES_JSON='["Library/Caches"]'
else
  EXCLUDES_JSON='["Library/Caches", "Documents/Books", "Documents/audiobooks"]'
fi

# Compact metadata file — restore.sh validates against this before restoring.
# fixture_format_version: bump when the on-disk shape changes in a way that
# breaks back-compat (e.g. v2 might add a keychain blob). restore.sh hard-fails
# on a mismatch so old fixtures don't silently restore against newer logic.
cat > "$META" <<EOF
{
  "fixture_format_version": 1,
  "fixture_name": "$FIXTURE_NAME",
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "app_bundle_id": "$BUNDLE_ID",
  "app_version": "$APP_VERSION",
  "sim_udid": "$SIM_UDID",
  "sim_device": "$DEVICE_NAME",
  "includes_books": $INCLUDE_BOOKS,
  "excludes": $EXCLUDES_JSON
}
EOF

ARCHIVE_SIZE=$(du -h "$ARCHIVE" | awk '{print $1}')
echo "[snapshot] OK — $FIXTURE_NAME ($ARCHIVE_SIZE)"
echo "[snapshot] restore with: .palace-state/restore.sh $FIXTURE_NAME --app <path>"
