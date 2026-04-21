#!/bin/bash
# forgeos-gate-hook.sh -- Pre-PR governance check
# Called by Claude Code hook before `gh pr create`
# Exits 0 to allow, 1 to block
#
# Looks for a ForgeOS changeset matching the current branch.
# If found, runs gate-check. If not found, warns but allows
# (to avoid blocking work when ForgeOS is unreachable).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

API_URL="https://forgeos-api.synctek.io"
PROJECT_ID="proj_87884c17"

# Read API key
if [ -z "${FORGEOS_API_KEY:-}" ]; then
  FORGEOS_API_KEY=$(python3 -c "
import json
with open('${REPO_ROOT}/.cursor/mcp.json') as f:
    print(json.load(f)['mcpServers']['forgeos']['env']['FORGEOS_API_KEY'])
" 2>/dev/null || echo "")
fi

if [ -z "$FORGEOS_API_KEY" ]; then
  echo "[ForgeOS] Warning: No API key found. Allowing PR creation without governance check."
  exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Find the most recent changeset for this branch
CHANGESET_ID=$(curl -s \
  -H "X-ForgeOS-API-Key: $FORGEOS_API_KEY" \
  "${API_URL}/api/projects/${PROJECT_ID}/changesets?branch=${BRANCH}&limit=1" 2>/dev/null | \
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('items', data.get('changesets', []))
    if items:
        print(items[0]['id'])
except:
    pass
" 2>/dev/null)

if [ -z "$CHANGESET_ID" ]; then
  echo "[ForgeOS] No changeset found for branch '$BRANCH'."
  echo "[ForgeOS] Create one first: scripts/forgeos-session.sh start <initiative_id> $BRANCH <description>"
  echo ""
  echo "PR creation blocked. Every PR needs a ForgeOS changeset."
  exit 1
fi

echo "[ForgeOS] Found changeset $CHANGESET_ID for branch $BRANCH"

# Run gate check
MIN_TESTS="${FORGEOS_MIN_TESTS:-100}"
if bash "$SCRIPT_DIR/forgeos-session.sh" gate-check "$CHANGESET_ID" "$MIN_TESTS"; then
  echo ""
  echo "[ForgeOS] Governance check passed. PR creation allowed."
  exit 0
else
  echo ""
  echo "[ForgeOS] Governance check failed. PR creation blocked."
  echo ""
  echo "To resolve:"
  echo "  scripts/forgeos-session.sh evidence $CHANGESET_ID"
  echo "  scripts/forgeos-session.sh promote $CHANGESET_ID"
  exit 1
fi
