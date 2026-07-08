#!/usr/bin/env bash
#
# check_registry_snapshot_freshness.sh
#
# Emits an Xcode-style `warning:` line if Palace/Accounts/Library/bundled_registry.json
# is older than REGISTRY_SNAPSHOT_THRESHOLD_DAYS (default 30 days). Designed to
# run as an Xcode "Run Script" build phase AND as a Fastlane pre-build step,
# so distribution paths that bypass `fastlane refresh_registry_snapshot`
# (e.g. manual Xcode Organizer archives) still surface the stale-snapshot
# signal at build time.
#
# Always exits 0 — this is a developer-facing warning, not a hard gate.
# A missing snapshot file is logged as a warning too (a fresh checkout
# without `fastlane refresh_registry_snapshot` having ever run will hit
# this path).

set -euo pipefail

THRESHOLD_DAYS="${REGISTRY_SNAPSHOT_THRESHOLD_DAYS:-30}"

# Resolve project root: prefer Xcode's $SRCROOT (set in build-phase context),
# fall back to repo-root detection from the script's own location, then to cwd.
if [ -n "${SRCROOT:-}" ]; then
    SCRIPT_ROOT="$SRCROOT"
elif [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
    SCRIPT_ROOT="$(pwd)"
fi

SNAPSHOT_PATH="$SCRIPT_ROOT/Palace/Accounts/Library/bundled_registry.json"

if [ ! -f "$SNAPSHOT_PATH" ]; then
    echo "warning: bundled_registry.json missing at $SNAPSHOT_PATH — run 'fastlane refresh_registry_snapshot' before shipping" >&2
    exit 0
fi

now_epoch=$(date +%s)
# macOS uses `stat -f %m`, GNU uses `stat -c %Y`. Try BSD first, then GNU.
if file_epoch=$(stat -f %m "$SNAPSHOT_PATH" 2>/dev/null); then
    :
elif file_epoch=$(stat -c %Y "$SNAPSHOT_PATH" 2>/dev/null); then
    :
else
    echo "warning: bundled_registry.json freshness check could not read file mtime (unsupported stat)" >&2
    exit 0
fi

age_seconds=$(( now_epoch - file_epoch ))
age_days=$(( age_seconds / 86400 ))

if [ "$age_days" -gt "$THRESHOLD_DAYS" ]; then
    echo "warning: bundled_registry.json is $age_days days old (threshold ${THRESHOLD_DAYS}d) — run 'fastlane refresh_registry_snapshot' to refresh before shipping" >&2
fi

exit 0
