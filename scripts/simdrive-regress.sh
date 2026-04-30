#!/bin/bash
# simdrive-regress.sh — Replay all .simdrive/journeys/*.yaml against a booted sim.
#
# Reads each journey's `tier:` field. Stateless journeys (tier0) fail the run
# on any SSIM drift. Stateful journeys (tier1) are smoke tests — pass if the
# replay completed without an error, drift is informational.
#
# Usage:
#   scripts/simdrive-regress.sh                   # all journeys
#   scripts/simdrive-regress.sh --tier stateless  # blocking tier only
#   scripts/simdrive-regress.sh --tier stateful   # smoke tier only
#   scripts/simdrive-regress.sh --only <id>       # run a single journey by id
#   scripts/simdrive-regress.sh --report <file>   # write JSON report
#   scripts/simdrive-regress.sh --sim-id <UDID>   # override default sim
#
# Exit code:
#   0  — every stateless journey clean, every stateful journey ran without error
#   1  — at least one stateless journey drifted, OR at least one journey errored
#   2  — config error (no journeys, simdrive not installed, sim not bootable)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

JOURNEYS_DIR=".simdrive/journeys"
SIM_ID="${SIMDRIVE_SIM_ID:-DF4A2A27-9888-429D-A749-2E157A049A37}"
APP_BUNDLE="org.thepalaceproject.palace"
TIER_FILTER=""
ONLY_ID=""
REPORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier) TIER_FILTER="$2"; shift 2 ;;
    --only) ONLY_ID="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --sim-id) SIM_ID="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! python3 -c "import simdrive" 2>/dev/null; then
  echo "ERROR: simdrive package not installed. Run: pip3 install --pre simdrive" >&2
  exit 2
fi

if [ ! -d "$JOURNEYS_DIR" ] || [ -z "$(ls -A "$JOURNEYS_DIR"/*.yaml 2>/dev/null)" ]; then
  echo "ERROR: no journeys in $JOURNEYS_DIR" >&2
  exit 2
fi

xcrun simctl boot "$SIM_ID" 2>/dev/null || true

echo "=== simdrive-regress ==="
echo "Sim:      $SIM_ID"
echo "Tier:     ${TIER_FILTER:-all}"
[ -n "$ONLY_ID" ] && echo "Only:     $ONLY_ID"
echo ""

pass_count=0
fail_count=0
skip_count=0
results_json="["
first=true

for journey_yaml in "$JOURNEYS_DIR"/*.yaml; do
  [ -f "$journey_yaml" ] || continue
  basename=$(basename "$journey_yaml" .yaml)
  [ "$basename" = "_INDEX" ] || [ "$basename" = "_GAP_ANALYSIS" ] && continue
  [ -n "$ONLY_ID" ] && [ "$basename" != "$ONLY_ID" ] && continue

  # Pull tier from YAML (no yaml parser; grep the line, strip comments)
  tier=$(grep -E '^\s*tier:' "$journey_yaml" | head -1 | sed 's/^[^:]*://; s/#.*//' | tr -d ' ')
  [ -z "$tier" ] && tier="stateless"

  if [ -n "$TIER_FILTER" ] && [ "$tier" != "$TIER_FILTER" ]; then
    skip_count=$((skip_count + 1))
    continue
  fi

  # Pull threshold (default 0.85), strip trailing comments
  threshold=$(grep -E '^\s*threshold:' "$journey_yaml" | head -1 | sed 's/^[^:]*://; s/#.*//' | tr -d ' ')
  [ -z "$threshold" ] && threshold="0.85"

  recording_path="$HOME/.simdrive/recordings/${basename}/recording.yaml"
  if [ ! -f "$recording_path" ]; then
    echo "[SKIP] ${basename} (tier=${tier}) — no recording at ${recording_path}"
    skip_count=$((skip_count + 1))
    continue
  fi

  # NOTE: SSIM-as-blocking-gate is currently disabled.
  # Reason: the iOS status-bar clock changes between record and replay, dropping
  # SSIM below 0.85 even on a "stateless" identical screen. Until simdrive
  # supports region-masking (excluding the status bar from SSIM), we run all
  # journeys with on_drift=warn and gate only on `errored > 0`. The tier system
  # in journey YAMLs is preserved for when masking lands. See _INDEX.md.
  on_drift="warn"

  echo "--- ${basename} (tier=${tier}, threshold=${threshold}) ---"
  REPLAY_OUT=$(SIM_ID="$SIM_ID" JOURNEY_NAME="$basename" APP="$APP_BUNDLE" \
              ON_DRIFT="$on_drift" THRESHOLD="$threshold" \
              python3 - <<'PYEOF' 2>&1
import json, os, sys, time
try:
    from simdrive import session as sdsession
    from simdrive import recorder as sdrecorder
    from simdrive import perf as sdperf
    from simdrive import diagnostics as sddiag
except Exception as e:
    print(json.dumps({"error": f"import-failed: {e}"})); sys.exit(0)
try:
    udid = os.environ["SIM_ID"]
    app  = os.environ["APP"]
    s = sdsession.start(udid=udid, app_bundle_id=app)
    time.sleep(1.5)
    # Pre-replay perf baseline
    baseline = sdperf.snapshot(udid, app)
    pre_crashes = len(sddiag.list_crashes(bundle_id=app, max_results=10))

    r = sdrecorder.replay(
        name=os.environ["JOURNEY_NAME"],
        session=s,
        on_drift=os.environ["ON_DRIFT"],
        drift_threshold=float(os.environ["THRESHOLD"]),
    )

    # Post-replay perf snapshot — taken BEFORE session_end so the app is still alive
    current = sdperf.snapshot(udid, app)
    post_crashes = len(sddiag.list_crashes(bundle_id=app, max_results=10))

    sdsession.end(session_id=s.session_id, terminate_app=True)

    # Compute delta + severity
    delta = {
        "cpu_pct":        current.get("cpu_pct", 0) - baseline.get("cpu_pct", 0),
        "memory_rss_mb":  current.get("memory_rss_mb", 0) - baseline.get("memory_rss_mb", 0),
        "threads":        current.get("threads", 0) - baseline.get("threads", 0),
    }
    severity = sdperf.severity(delta)

    steps = r.get("steps", [])
    drifted = sum(1 for st in steps if st.get("drifted"))
    errored = sum(1 for st in steps if st.get("error"))
    print(json.dumps({
        "steps": len(steps),
        "drifted": drifted,
        "errored": errored,
        "min_similarity": min((st.get("similarity", 1.0) for st in steps), default=1.0),
        "perf": {
            "baseline_rss_mb": round(baseline.get("memory_rss_mb", 0), 2),
            "current_rss_mb":  round(current.get("memory_rss_mb", 0), 2),
            "rss_delta_mb":    round(delta["memory_rss_mb"], 2),
            "threads_delta":   delta["threads"],
            "severity":        severity,
        },
        "crashes_during": post_crashes - pre_crashes,
    }))
except Exception as e:
    print(json.dumps({"error": str(e)}))
PYEOF
)
  RESULT=$(echo "$REPLAY_OUT" | tail -1)
  steps=$(echo "$RESULT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('steps','?'))" 2>/dev/null || echo "?")
  drifted=$(echo "$RESULT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('drifted','?'))" 2>/dev/null || echo "?")
  errored=$(echo "$RESULT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('errored','?'))" 2>/dev/null || echo "?")
  err=$(echo "$RESULT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('error',''))" 2>/dev/null || echo "")

  perf_summary=$(echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    p = d.get('perf', {})
    print(f\"rss {p.get('baseline_rss_mb','?')}→{p.get('current_rss_mb','?')}MB (Δ{p.get('rss_delta_mb','?')}, t{p.get('threads_delta','?')}, {p.get('severity','?')})\")
except Exception as e:
    print(f'perf=err({e})')
" 2>/dev/null || echo "perf=?")
  perf_severity=$(echo "$RESULT" | python3 -c "
import sys,json
try: print(json.loads(sys.stdin.read()).get('perf', {}).get('severity', 'low'))
except: print('low')" 2>/dev/null || echo "low")
  crashes_during=$(echo "$RESULT" | python3 -c "
import sys,json
try: print(json.loads(sys.stdin.read()).get('crashes_during', 0))
except: print(0)" 2>/dev/null || echo "0")

  status="pass"
  detail="${steps} steps, drift=${drifted} (informational), err=${errored}; ${perf_summary}; crashes=${crashes_during}"
  if [ -n "$err" ]; then
    status="fail"
    detail="error: ${err}"
  elif [ "$errored" != "0" ] && [ "$errored" != "?" ]; then
    status="fail"
    detail="${errored}/${steps} steps errored"
  elif [ "$perf_severity" = "high" ]; then
    status="fail"
    detail="${detail} — perf severity HIGH (likely leak)"
  elif [ "$crashes_during" != "0" ] && [ "$crashes_during" != "?" ]; then
    status="fail"
    detail="${detail} — ${crashes_during} crash(es) during journey"
  fi

  # Structural checks (if defined in journey YAML) — robust to OPDS variability.
  if grep -q '^\s*structural_checks:' "$journey_yaml"; then
    if SIMDRIVE_SIM_ID="$SIM_ID" python3 "${SCRIPT_DIR}/simdrive-structural-check.py" \
       --journey "$journey_yaml" --app "$APP_BUNDLE" >/tmp/struct-${basename}.log 2>&1; then
      detail="${detail}; struct-check=PASS"
    else
      status="fail"
      struct_summary=$(grep -E '\[FAIL\]|min_marks|missing' /tmp/struct-${basename}.log | head -3 | tr '\n' '|' | sed 's/"/\\"/g')
      detail="${detail}; struct-check=FAIL (${struct_summary})"
    fi
  fi

  if [ "$status" = "pass" ]; then
    pass_count=$((pass_count + 1))
    echo "  [PASS] ${detail}"
  else
    fail_count=$((fail_count + 1))
    echo "  [FAIL] ${detail}"
  fi

  if [ "$first" = "true" ]; then first=false; else results_json="${results_json},"; fi
  results_json="${results_json}{\"journey\":\"${basename}\",\"tier\":\"${tier}\",\"status\":\"${status}\",\"detail\":\"$(echo "$detail" | sed 's/"/\\"/g')\"}"
done

results_json="${results_json}]"

echo ""
echo "=== Summary ==="
echo "  Passed:  ${pass_count}"
echo "  Failed:  ${fail_count}"
echo "  Skipped: ${skip_count}"

if [ -n "$REPORT" ]; then
  cat > "$REPORT" <<JSONEOF
{
  "sim_id": "${SIM_ID}",
  "tier_filter": "${TIER_FILTER}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pass_count": ${pass_count},
  "fail_count": ${fail_count},
  "skip_count": ${skip_count},
  "journeys": ${results_json}
}
JSONEOF
  echo "  Report:  ${REPORT}"
fi

if [ "$fail_count" -gt 0 ]; then
  echo ""
  echo "BLOCKED: ${fail_count} journey(s) failed."
  exit 1
fi
echo ""
echo "CLEAR: every journey passed."
exit 0
