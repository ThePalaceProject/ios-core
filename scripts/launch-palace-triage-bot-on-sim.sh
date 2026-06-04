#!/usr/bin/env bash
# Launch Palace on the booted iOS simulator with ANTHROPIC_API_KEY pre-set,
# so the triage-bot AI fallback (ClaudeFallbackClassifier) is wired
# end-to-end for chaos-qa runs and ad-hoc local testing.
#
# Reads the key from the developer's Xcode scheme (xcuserdata-style — the
# Palace.xcscheme file is gitignored per .gitignore, never shipped).
# The script never echoes the key to stdout or any log.
#
# Usage:
#   scripts/launch-palace-triage-bot-on-sim.sh                  # uses booted sim
#   scripts/launch-palace-triage-bot-on-sim.sh <udid>           # specific sim
#
# Requires: a booted iOS simulator with Palace already installed.
#           ANTHROPIC_API_KEY env var set in Palace.xcscheme.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="$REPO_ROOT/Palace.xcodeproj/xcshareddata/xcschemes/Palace.xcscheme"
BUNDLE_ID="org.thepalaceproject.palace"

if [[ ! -f "$SCHEME" ]]; then
  echo "error: scheme not found at $SCHEME" >&2
  exit 1
fi

# Extract ANTHROPIC_API_KEY value from the scheme XML. The plist format is:
#   <EnvironmentVariable
#       key = "ANTHROPIC_API_KEY"
#       value = "sk-ant-..."
#       isEnabled = "YES">
# We pull the value via awk; never write the key to disk anywhere new.
KEY="$(awk '
  /ANTHROPIC_API_KEY/ { capture = 1; next }
  capture && /value/ {
    match($0, /value = "[^"]+"/)
    if (RSTART) {
      v = substr($0, RSTART + 9, RLENGTH - 10)
      print v
    }
    exit
  }
' "$SCHEME")"

if [[ -z "$KEY" ]]; then
  echo "error: ANTHROPIC_API_KEY not found in $SCHEME" >&2
  echo "  set it via: Xcode → Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables" >&2
  exit 1
fi

UDID="${1:-$(xcrun simctl list devices booted | awk '/Booted/ {print $NF; exit}' | tr -d '()')}"
if [[ -z "$UDID" ]]; then
  echo "error: no booted sim — boot one in Simulator.app or pass a UDID as arg" >&2
  exit 1
fi

# Terminate any running instance so the env var takes effect on cold launch.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# Launch with the env var. simctl propagates SIMCTL_CHILD_* vars into the
# child process environment (see `simctl launch --help`). The key is NOT
# passed via --env flag (which simctl launch does not support) and does NOT
# appear in `ps` listings or shell history.
SIMCTL_CHILD_ANTHROPIC_API_KEY="$KEY" xcrun simctl launch "$UDID" \
  "$BUNDLE_ID"

echo "Palace launched on $UDID with ANTHROPIC_API_KEY in env." >&2
echo "AI fallback should be active after the AnthropicKeyStore bootstrap fires." >&2
