#!/usr/bin/env bash
# record-auth-flow.sh — Record a Palace simdrive auth-signin flow with credentials
# pulled safely from the macOS Keychain–backed harness vault.
#
# The recording produces a `.simdrive/recordings/<name>/recording.yaml` file
# that future PR-gate replays can run with the Layer-2 state contract.
#
# USAGE:
#   scripts/record-auth-flow.sh <recording-name> <creds-slug> [--sim <UDID>]
#
# EXAMPLES:
#   # A1QA Test Library — basic auth (barcode + PIN)
#   scripts/record-auth-flow.sh a1qa-basic-signin palace-ios.lib.a1qa
#
#   # Danny Test Library on Gorgon — SAML
#   scripts/record-auth-flow.sh danny-saml-signin palace-ios.lib.danny-test-gorgon
#
# PRECONDITIONS:
#   - simdrive 1.0.0a9+ installed (`pip3 install --pre simdrive`)
#   - Palace.app installed on the target sim
#   - The library you're signing into is already added under Settings → Libraries
#     (this script does NOT do the Add-Library flow — Palace's Add-Library
#     picker has a multi-step confirmation that's easier to drive interactively)
#   - `harness creds list` shows the creds-slug you're passing
#
# THE RECORDING FLOW
#
# Recording captures the sign-in form interaction starting from the library
# Account view (Settings → Libraries → <library> → "Sign In"). The script:
#   1. Pulls creds via `harness creds export` into env vars — values are
#      NEVER echoed to stdout/stderr.
#   2. Sets the macOS pasteboard via `pbcopy` so the typed credentials use
#      the simulator's Cmd-V chord (avoids simdrive 1.0.0a5's type_text
#      case-mangling for mixed-case PINs).
#   3. Starts a simdrive recording.
#   4. Waits for you to drive the sign-in form to completion (the human
#      part — clicking Sign In, handling 2FA prompts if needed).
#   5. On 'q' enter, stops recording and runs `migrate-recording --force`
#      to backfill the Layer-2 state contract from the step-0 screenshot.
#   6. Lints the recording via `lint-recordings`.

set -eu

# Clear clipboard on any exit so credentials don't leak to Spotlight history,
# clipboard managers, or an accidental paste into Slack.
trap 'pbcopy < /dev/null' EXIT

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 2 ]; then
  grep -E "^#" "$0" | sed 's|^# \?||'
  exit 0
fi

NAME="$1"
SLUG="$2"
shift 2
SIM_UDID="${SIM_UDID:-$(xcrun simctl list devices iPhone | awk '/Booted/ {print $NF; exit}' | tr -d '()')}"
while [ $# -gt 0 ]; do
  case "$1" in
    --sim) SIM_UDID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SIM_UDID" ]; then
  echo "ERROR: no booted iPhone sim. Pass --sim <UDID> or boot one first." >&2
  exit 1
fi

# Validate the creds slug exists before we go further.
if ! ~/harness/bin/harness creds list 2>/dev/null | grep -Fxq "$SLUG"; then
  echo "ERROR: creds slug '$SLUG' not in harness vault." >&2
  echo "Available slugs:" >&2
  ~/harness/bin/harness creds list 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

# Inject creds as env vars WITHOUT echoing values.
# `harness creds export` emits `export HARNESS_USER=...` lines; `eval`
# them into the current shell. Nothing reaches stdout.
eval "$(~/harness/bin/harness creds export "$SLUG" 2>/dev/null)"
if [ -z "${HARNESS_USER:-}" ] || [ -z "${HARNESS_PASS:-}" ]; then
  echo "ERROR: $SLUG didn't yield HARNESS_USER + HARNESS_PASS." >&2
  exit 1
fi

echo "[record-auth-flow] Sim: $SIM_UDID"
echo "[record-auth-flow] Creds slug: $SLUG (loaded into env, values not echoed)"
echo "[record-auth-flow] Recording name: $NAME"
echo ""
echo "PRE-FLIGHT CHECKLIST:"
echo "  1. The target library is added under Settings → Libraries."
echo "  2. You're signed OUT of the library (Account view shows 'Sign in')."
echo "  3. The Account view is in the foreground."
echo ""
read -p "Press Enter when ready to start recording, or Ctrl-C to abort... " _

# Pre-stage the pasteboard with the password so step-N Cmd-V picks it up.
# Replace with HARNESS_PASS when ready to paste; you'll need to re-pbcopy
# the barcode for that field too.
echo -n "$HARNESS_USER" | pbcopy
echo "[record-auth-flow] Username copied to pasteboard. Tap the username/barcode field, then Cmd-V."
echo ""

# Start recording via simdrive CLI. The CLI is interactive when invoked
# directly — it stops when you press Enter / q.
#
# NAME + SIM_UDID are passed via environment so a malicious recording name
# (e.g. one containing `'); __import__('os').system('rm -rf ~')` ) can't
# break out of the embedded Python source. The heredoc reads them from
# os.environ inside the interpreter, where they're inert strings.
NAME="$NAME" SIM_UDID="$SIM_UDID" python3 <<'PYEOF'
import os
from simdrive import session as sd, recorder
name = os.environ['NAME']
udid = os.environ['SIM_UDID']
sess = sd.start(target='simulator', udid=udid, app_bundle_id='org.thepalaceproject.palace')
print(f'[record-auth-flow] Session: {sess.id}')
print(f'[record-auth-flow] Starting recording... drive the sign-in flow now.')
print('[record-auth-flow] When done, press Enter to stop recording.')
recorder.record_start(sess, name=name)
input()
recorder.record_stop(sess)
print('[record-auth-flow] Recording stopped.')
sess.end()
PYEOF

REC_DIR=~/.simdrive/recordings/"$NAME"
if [ ! -d "$REC_DIR" ]; then
  echo "ERROR: recording dir not found at $REC_DIR — record_stop must have failed." >&2
  exit 1
fi

# Backfill the Layer-2 state contract from the step-0 screenshot.
echo "[record-auth-flow] Backfilling state contract..."
simdrive migrate-recording --force "$NAME" || true

# Lint the recording corpus.
echo "[record-auth-flow] Linting corpus..."
simdrive lint-recordings || true

echo ""
echo "[record-auth-flow] DONE. Recording at $REC_DIR/recording.yaml"
echo "[record-auth-flow] Next: copy to project corpus + replay to verify:"
echo "    simdrive replay $NAME --on-drift warn"
