#!/usr/bin/env bash
#
# chaos-replay.sh — deterministically replay the curated chaos corpus
# (.simdrive/replays/chaos/) against an installed candidate build and gate on
# SSIM drift. This is the runnable core of the chaos-replay-on-pr.yml gate.
#
# WHY THIS SCRIPT EXISTS (the bug it fixes):
#   The workflow previously invoked `simdrive replay --name ... --on-drift halt`.
#   That CLI subcommand DOES NOT EXIST — `replay` is exposed only as an MCP tool
#   and via the Python API `simdrive.recorder.replay(...)`. The CLI surface is
#   `run` / `ci` / `lint-recordings` / `migrate-recording` (see `simdrive --help`).
#   Separately, the replay engine resolves a recording NAME against
#   `recorder.recordings_root()` (== `$SIMDRIVE_HOME/recordings`, default
#   `~/.simdrive/recordings/<name>/recording.yaml`) — NOT the in-repo corpus path
#   `.simdrive/replays/chaos/<name>/`. So even a corrected command would find
#   nothing to replay.
#
# THE FIX (mirrors the proven path in scripts/regression-area-worker.sh):
#   1. Stage each corpus recording dir `.simdrive/replays/chaos/<name>/` into
#      `recordings_root()/<name>/` so the engine can resolve it.
#   2. Replay via the Python API: `session.start(udid=...)` +
#      `recorder.replay(name, session, on_drift="halt", drift_threshold=T)`.
#   3. Classify the result dict with `regression_findings.classify_replay` — the
#      same anti-false-pass gate the fleet worker uses (a replay that executed
#      0/N planned steps, or halted on a precondition mismatch, is a FAILURE,
#      never a pass).
#
# Usage:
#   scripts/chaos-replay.sh --udid <UDID> [--corpus DIR] [--threshold 0.85]
#   scripts/chaos-replay.sh --check [--corpus DIR]   # validate+stage only, no sim
#
# --check validates that every top-level <name>.yaml has a replayable
# <name>/recording.yaml payload and that staging succeeds. It does NOT boot a
# sim or replay, so it runs anywhere (used by the unit test + local dry-runs).
#
# Exit: 0 = all replays passed (or --check clean); 1 = a replay diverged / a
# corpus entry is malformed; 2 = config error (no simdrive, bad args, no corpus).
set -euo pipefail

CORPUS=".simdrive/replays/chaos"
THRESHOLD="0.85"
UDID=""
CHECK_ONLY=0
APP_BUNDLE="${CHAOS_APP_BUNDLE:-org.thepalaceproject.palace}"

die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)      UDID="$2"; shift 2 ;;
    --corpus)    CORPUS="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --check)     CHECK_ONLY=1; shift ;;
    -h|--help)   grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown arg: $1" ;;
  esac
done

[[ -d "$CORPUS" ]] || die "corpus dir not found: $CORPUS"
# simdrive is only needed to actually replay (Python API). --check just stages
# + validates, so it stays runnable on a bare CI runner without simdrive/Xcode.
if [[ "$CHECK_ONLY" == "0" ]]; then
  [[ -n "$UDID" ]] || die "--udid is required unless --check is passed"
  python3 -c "import simdrive" 2>/dev/null \
    || die "simdrive package not installed. Run: pip3 install --pre simdrive"
fi

# Enumerate corpus entries by their top-level <name>.yaml (the workflow's glob).
shopt -s nullglob
specs=("$CORPUS"/*.yaml)
shopt -u nullglob
if [[ ${#specs[@]} -eq 0 ]]; then
  echo "no chaos replays in $CORPUS/*.yaml — nothing to verify; clean."
  exit 0
fi

# recorder.recordings_root() == ${SIMDRIVE_HOME:-~/.simdrive}/recordings. Resolve
# it the same way without importing simdrive, so --check runs on a bare runner.
REC_ROOT="${SIMDRIVE_HOME:-$HOME/.simdrive}/recordings"
mkdir -p "$REC_ROOT"

# --- Stage + validate every entry (both modes need a resolvable recording) ---
names=()
for spec in "${specs[@]}"; do
  name="$(basename "$spec" .yaml)"
  payload="$CORPUS/$name/recording.yaml"
  if [[ ! -f "$payload" ]]; then
    echo "::error::chaos corpus entry '$name' has no replay payload at $payload" >&2
    echo "  A curated entry needs BOTH the top-level $name.yaml (enumerated by the" >&2
    echo "  gate) AND a $name/recording.yaml dir (the replayable HID trace)." >&2
    exit 1
  fi
  # Stage the recording dir into recordings_root so recorder.replay(name) resolves it.
  dest="$REC_ROOT/$name"
  rm -rf "$dest"
  cp -R "$CORPUS/$name" "$dest"
  names+=("$name")
done
echo "staged ${#names[@]} chaos recording(s) into $REC_ROOT: ${names[*]}"

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "--check OK: ${#names[@]} corpus entr(y|ies) well-formed and stageable."
  exit 0
fi

# --- Replay each staged recording via the Python API, classify with the
#     canonical anti-false-pass gate (regression_findings.classify_replay). ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
PASS=0
for name in "${names[@]}"; do
  echo "::group::$name"
  status="$(UDID="$UDID" APP="$APP_BUNDLE" NAME="$name" THRESHOLD="$THRESHOLD" \
            SCRIPT_DIR="$SCRIPT_DIR" python3 - <<'PY'
import json, os, sys, time
sys.path.insert(0, os.environ["SCRIPT_DIR"])
try:
    from simdrive import session as sds
    from simdrive import recorder as sdr
    from regression_findings import classify_replay
except Exception as e:
    print(json.dumps({"status": "error", "reason": f"import-failed: {e}"}))
    sys.exit(0)

udid = os.environ["UDID"]
app = os.environ["APP"]
name = os.environ["NAME"]
threshold = float(os.environ["THRESHOLD"])
try:
    import subprocess as sp
    sp.run(["xcrun", "simctl", "terminate", udid, app], capture_output=True)
    time.sleep(1.0)
    s = sds.start(udid=udid, app_bundle_id=app)
    time.sleep(2.0)
    result = sdr.replay(name, s, on_drift="halt", drift_threshold=threshold)
    verdict = classify_replay(result)
    print(json.dumps(verdict))
except Exception as e:
    print(json.dumps({"status": "error", "reason": f"replay-raised: {e}"}))
PY
)"
  echo "$status"
  st="$(printf '%s' "$status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","error"))' 2>/dev/null || echo error)"
  if [[ "$st" == "pass" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "::error::Replay $name did not pass ($st) — a chaos-discovered regression may have reappeared"
  fi
  echo "::endgroup::"
done

echo "chaos-replay: $PASS passed, $FAIL failed (of ${#names[@]})"
[[ "$FAIL" == "0" ]]
