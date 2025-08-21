#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

run_case() {
  local title="$1"; shift
  echo "\n=== $title ==="
  env -i PATH="$PATH" HOME="$HOME" \
    MD_APPLE_SDK_ROOT="${MD_APPLE_SDK_ROOT:-}" \
    DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    DRY_RUN=1 \
    bash -lc './scripts/xcode-export-adhoc.sh' || true
}

echo "Smoke test starting in $ROOT_DIR"

# Case 1: DEVELOPER_DIR unset, MD_APPLE_SDK_ROOT present
if [ -x /usr/bin/xcode-select ]; then
  export MD_APPLE_SDK_ROOT="$(/usr/bin/xcode-select -p 2>/dev/null | sed 's#/Contents/Developer$##')"
else
  export MD_APPLE_SDK_ROOT=""
fi
unset DEVELOPER_DIR || true
run_case "Case 1: Only MD_APPLE_SDK_ROOT set (derive DEVELOPER_DIR)"

# Case 2: both unset -> fallback to xcode-select -p
unset MD_APPLE_SDK_ROOT || true
unset DEVELOPER_DIR || true
run_case "Case 2: Both unset (fallback to xcode-select -p)"

echo "\nSmoke test completed."


