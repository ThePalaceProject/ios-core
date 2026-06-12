#!/usr/bin/env bash
# regression-area-worker.sh — one shard of the fleet regression campaign.
#
# A shard = one (area-group × device-cell). The worker replays the area-group's
# simdrive journeys on its OWN dedicated keychain-reset sim, runs structural
# checks + perf delta + crash capture, ALWAYS writes a per-journey evidence log,
# captures a candidate screenshot (feeds the RC-VISUAL stage), and appends a
# findings.csv row (BUILD-PLAN schema, via scripts/regression_findings.py) for
# every real failure. No evidence ⇒ no finding (anti-hallucination).
#
# Conforms to REGRESSION-BUILD-PLAN.md shared contracts:
#   findings.csv schema + artifact dir layout + per-worker hermeticity.
#
# Usage:
#   regression-area-worker.sh --area-group <g> --run-dir <dir> \
#       [--device-cell C-iphone-26] [--sim-id <UDID>] [--manifest <path>] \
#       [--no-keychain-reset] [--chaos] [--dry-run]
#
#   --area-group   REQUIRED. One of the groups in the manifest (auth, circulation,
#                  reading, audiobook, catalog, ui-nav).
#   --run-dir      REQUIRED. Campaign run dir (e.g. .regression-runs/<run-id>).
#                  findings.csv + logs/ + candidates/ + crashes/ live under it.
#   --device-cell  Cell tag carried into findings + dir paths. Default C-iphone-26.
#                  The worker does NOT provision the cell (that's HC-DEVICE-CELLS);
#                  it runs against whatever sim --sim-id / HARNESS_SESSION_SIM_UDID
#                  points at and labels the output with this cell.
#   --sim-id       Sim UDID. Default: $HARNESS_SESSION_SIM_UDID (set by fleet
#                  _allocate_sim), else the first booted iPhone sim.
#   --manifest     Area-group manifest. Default .simdrive/regression-areas.json.
#   --no-keychain-reset  Skip the per-run keychain reset (default: reset, for
#                  hermeticity — a reused sim re-accumulates dirty auth state).
#   --chaos        After the journey pass, also run the chaos fan for THIS area.
#   --dry-run      Resolve + print the plan; don't touch the sim.
#
# Exit codes:
#   0 — worker completed (findings, if any, are in findings.csv — the exit code
#       is NOT the gate; the campaign reads findings.csv).
#   2 — config error (bad args, no sim, simdrive missing, unknown area-group).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

APP_BUNDLE="org.thepalaceproject.palace"
MANIFEST=".simdrive/regression-areas.json"
JOURNEYS_DIR=".simdrive/journeys"
FINDINGS="$SCRIPT_DIR/regression_findings.py"

AREA_GROUP=""
RUN_DIR=""
DEVICE_CELL="C-iphone-26"
SIM_ID="${HARNESS_SESSION_SIM_UDID:-}"
KEYCHAIN_RESET=1
RUN_CHAOS=0
DRY_RUN=0

die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --area-group) AREA_GROUP="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --device-cell) DEVICE_CELL="$2"; shift 2 ;;
    --sim-id) SIM_ID="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --no-keychain-reset) KEYCHAIN_RESET=0; shift ;;
    --chaos) RUN_CHAOS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$AREA_GROUP" ]] || die "--area-group is required"
[[ -n "$RUN_DIR" ]] || die "--run-dir is required"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

if ! python3 -c "import simdrive" 2>/dev/null; then
  die "simdrive package not installed. Run: pip3 install --pre simdrive"
fi

# Resolve journeys for the area-group (also validates the group exists).
# Portable read loop (macOS bash 3.2 has no `mapfile`).
JOURNEYS=()
while IFS= read -r _line; do
  [[ -n "$_line" ]] && JOURNEYS+=("$_line")
done < <(python3 "$FINDINGS" journeys "$MANIFEST" "$AREA_GROUP" 2>/dev/null)
if [[ ${#JOURNEYS[@]} -eq 0 ]]; then
  # Distinguish "unknown group" (python errors) from "group with no journeys".
  python3 "$FINDINGS" journeys "$MANIFEST" "$AREA_GROUP" >/dev/null 2>&1 \
    || die "unknown area-group '$AREA_GROUP' (see: python3 $FINDINGS areas $MANIFEST)"
  echo "warn: area-group '$AREA_GROUP' has no journeys; nothing to replay" >&2
fi

# Pick a sim if none provided.
if [[ -z "$SIM_ID" ]]; then
  SIM_ID="$(xcrun simctl list devices iPhone 2>/dev/null | grep Booted | head -1 | grep -oiE '[0-9a-f-]{36}' | head -1)"
  [[ -n "$SIM_ID" ]] || die "no --sim-id, no HARNESS_SESSION_SIM_UDID, no booted iPhone sim"
fi

FIRST_SEEN_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Artifact dirs (BUILD-PLAN layout).
LOGS_DIR="$RUN_DIR/logs/$DEVICE_CELL/$AREA_GROUP"
CAND_DIR="$RUN_DIR/candidates/$DEVICE_CELL/$AREA_GROUP"
CRASH_DIR="$RUN_DIR/crashes/$DEVICE_CELL"
# Per-shard findings (palace-pm concurrency design): this worker owns
# <run-dir>/findings/<cell>__<area>.csv — never a shared findings.csv — so
# parallel workers never race on append. RC-CAMPAIGN merges shards → master.
FINDINGS_CSV="$RUN_DIR/findings/${DEVICE_CELL}__${AREA_GROUP}.csv"

echo "=== regression-area-worker ==="
echo "area-group:  $AREA_GROUP"
echo "device-cell: $DEVICE_CELL"
echo "sim:         $SIM_ID"
echo "run-dir:     $RUN_DIR"
echo "journeys:    ${JOURNEYS[*]:-<none>}"
echo "keychain:    $([[ $KEYCHAIN_RESET -eq 1 ]] && echo reset || echo keep)"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] would reset keychain, replay ${#JOURNEYS[@]} journey(s), and"
  echo "[dry-run] emit findings to $FINDINGS_CSV"
  [[ $RUN_CHAOS -eq 1 ]] && echo "[dry-run] would then run chaos fan for area '$AREA_GROUP'"
  exit 0
fi

mkdir -p "$LOGS_DIR" "$CAND_DIR" "$CRASH_DIR"
python3 "$FINDINGS" init-csv "$FINDINGS_CSV"

# Hermeticity: per-run keychain reset (a reused sim re-accumulates dirty auth
# state — see QUEUED-INFRA / the keychain-auth-state pollution class).
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
if [[ $KEYCHAIN_RESET -eq 1 ]]; then
  echo "--- keychain reset ($SIM_ID) ---"
  xcrun simctl keychain "$SIM_ID" reset 2>&1 | tail -1 || true
fi

pass_count=0
fail_count=0
skip_count=0
finding_count=0

for journey in "${JOURNEYS[@]}"; do
  journey_yaml="$JOURNEYS_DIR/$journey.yaml"
  if [[ ! -f "$journey_yaml" ]]; then
    echo "[SKIP] $journey — no journey YAML at $journey_yaml" >&2
    skip_count=$((skip_count + 1))
    continue
  fi

  recording="$HOME/.simdrive/recordings/$journey/recording.yaml"
  if [[ ! -f "$recording" ]]; then
    echo "[SKIP] $journey — no recording at $recording"
    skip_count=$((skip_count + 1))
    continue
  fi

  threshold="$(grep -E '^\s*threshold:' "$journey_yaml" | head -1 | sed 's/^[^:]*://; s/#.*//' | tr -d ' ')"
  [[ -z "$threshold" ]] && threshold="0.85"

  log_file="$LOGS_DIR/$journey.log"
  cand_png="$CAND_DIR/$journey-final.png"
  crash_json="$CRASH_DIR/$journey-crashes.json"

  echo "--- $journey (threshold=$threshold) ---"
  # The replay heredoc writes its own evidence (log file, candidate screenshot,
  # crash dump) and prints a one-line JSON verdict on the last line.
  VERDICT="$(SIM_ID="$SIM_ID" APP="$APP_BUNDLE" JOURNEY="$journey" \
             THRESHOLD="$threshold" LOG_FILE="$log_file" CAND_PNG="$cand_png" \
             CRASH_JSON="$crash_json" SCRIPT_DIR="$SCRIPT_DIR" \
             python3 - <<'PYEOF' 2>>"$log_file"
import json, os, shutil, sys, time
from pathlib import Path

ev = {"steps": 0, "steps_planned": 0, "steps_executed": 0, "drifted": 0,
      "errored": 0, "halt_reason": "", "replay_status": "error",
      "replay_reason": "replay did not run", "perf_severity": "low",
      "crashes_during": 0, "crash_file": "", "screenshot": "", "error": ""}
try:
    from simdrive import session as sds
    from simdrive import recorder as sdr
    from simdrive import perf as sdp
    from simdrive import diagnostics as sdd
    from simdrive import observe as sdo
except Exception as e:
    ev["error"] = f"import-failed: {e}"
    print(json.dumps(ev)); sys.exit(0)

udid = os.environ["SIM_ID"]
app = os.environ["APP"]
log_file = Path(os.environ["LOG_FILE"])
cand_png = Path(os.environ["CAND_PNG"])
crash_json = Path(os.environ["CRASH_JSON"])

start_ts = time.time()
try:
    s = sds.start(udid=udid, app_bundle_id=app)
    time.sleep(1.5)
    baseline = sdp.snapshot(udid, app)

    r = sdr.replay(name=os.environ["JOURNEY"], session=s,
                   on_drift="warn", drift_threshold=float(os.environ["THRESHOLD"]))

    current = sdp.snapshot(udid, app)
    # Scope to crashes since this run started (since_ts) rather than a pre/post
    # count delta — that delta could go negative if the list_crashes window shifts.
    # crashes_since re-applies the run-scoping as a tested pure invariant so a
    # crash predating the run can never yield a finding.
    sys.path.insert(0, os.environ["SCRIPT_DIR"])
    from regression_findings import crashes_since, classify_replay
    post = crashes_since(
        sdd.list_crashes(since_ts=start_ts, bundle_id=app, max_results=20),
        start_ts,
    )

    # Candidate screenshot + recent logs (evidence) while the app is still alive.
    # observe writes its raw observe-<ts>.png/json to a throwaway temp dir; we
    # keep only the named copy at <journey>-final.png so the candidates/ dir holds
    # exactly the per-journey screenshots RC-VISUAL diffs against the baselines.
    try:
        import tempfile
        obs_tmp = Path(tempfile.mkdtemp(prefix="rc-observe-"))
        obsv = sdo.observe(udid, out_dir=obs_tmp, annotate=False,
                           capture_logs=True, log_lines=200)
        if obsv.screenshot_path and Path(obsv.screenshot_path).exists():
            shutil.copy(obsv.screenshot_path, cand_png)
            ev["screenshot"] = str(cand_png)
        shutil.rmtree(obs_tmp, ignore_errors=True)
        if getattr(obsv, "recent_logs", None):
            with log_file.open("a") as lf:
                lf.write("\n--- recent_logs (simdrive observe) ---\n")
                lf.write("\n".join(obsv.recent_logs) + "\n")
    except Exception as e:
        with log_file.open("a") as lf:
            lf.write(f"\n[warn] observe failed: {e}\n")

    sds.end(session_id=s.session_id, terminate_app=True)

    delta = {
        "cpu_pct": current.get("cpu_pct", 0) - baseline.get("cpu_pct", 0),
        "memory_rss_mb": current.get("memory_rss_mb", 0) - baseline.get("memory_rss_mb", 0),
        "threads": current.get("threads", 0) - baseline.get("threads", 0),
    }
    # Anti-false-pass guard: classify the replay by executed-vs-planned steps +
    # halt reason. A 0-executed / halted / incomplete replay is fail/error here,
    # NEVER pass — a state-contract halt at step 0 means nothing was exercised.
    rv = classify_replay(r)
    ev["steps_planned"] = rv["steps_planned"]
    ev["steps_executed"] = rv["steps_executed"]
    ev["steps"] = rv["steps_executed"]
    ev["drifted"] = rv["drifted"]
    ev["errored"] = rv["errored"]
    ev["halt_reason"] = rv["halt_reason"]
    ev["replay_status"] = rv["status"]
    ev["replay_reason"] = rv["reason"]
    ev["perf_severity"] = sdp.severity(delta)
    ev["crashes_during"] = len(post)

    if ev["crashes_during"] > 0:
        # Persist the crash report(s) as evidence; copy raw files if present.
        new = post
        crash_json.write_text(json.dumps(new, indent=2, default=str))
        ev["crash_file"] = str(crash_json)
        for c in new:
            p = c.get("path") if isinstance(c, dict) else None
            if p and Path(p).exists():
                dest = crash_json.parent / Path(p).name
                try:
                    shutil.copy(p, dest)
                except Exception:
                    pass

    with log_file.open("a") as lf:
        lf.write("\n--- verdict ---\n" + json.dumps(ev, indent=2) + "\n")
except Exception as e:
    ev["error"] = str(e)
    with log_file.open("a") as lf:
        lf.write(f"\n[error] {e}\n")

print(json.dumps(ev))
PYEOF
)"
  VERDICT="$(echo "$VERDICT" | tail -1)"

  errored="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('errored',0))" 2>/dev/null || echo "?")"
  perf_sev="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('perf_severity','low'))" 2>/dev/null || echo "low")"
  crashes="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('crashes_during',0))" 2>/dev/null || echo "0")"
  err="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('error',''))" 2>/dev/null || echo "")"
  crash_file="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('crash_file',''))" 2>/dev/null || echo "")"
  screenshot="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('screenshot',''))" 2>/dev/null || echo "")"
  replay_status="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('replay_status','error'))" 2>/dev/null || echo "error")"
  replay_reason="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('replay_reason',''))" 2>/dev/null || echo "")"
  steps_exec="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('steps_executed',0))" 2>/dev/null || echo "0")"
  steps_planned="$(echo "$VERDICT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('steps_planned',0))" 2>/dev/null || echo "0")"

  # Structural checks (robust to OPDS variability) — failure is a finding.
  struct_status="n/a"; struct_log=""
  if grep -q '^\s*structural_checks:' "$journey_yaml"; then
    struct_log="$LOGS_DIR/$journey-struct.log"
    if SIMDRIVE_SIM_ID="$SIM_ID" python3 "$SCRIPT_DIR/simdrive-structural-check.py" \
       --journey "$journey_yaml" --app "$APP_BUNDLE" >"$struct_log" 2>&1; then
      struct_status="pass"
    else
      struct_status="fail"
    fi
  fi

  # Decide status + classification.
  status="pass"; classification="unknown"; reason=""
  if [[ -n "$err" ]]; then
    status="fail"; classification="other"; reason="replay-error: $err"
  elif [[ "$crashes" != "0" && "$crashes" != "?" ]]; then
    status="fail"; classification="crash"; reason="$crashes crash(es) during journey"
  elif [[ "$replay_status" != "pass" ]]; then
    # Anti-false-pass guard (the #1 integrity rule): a halted / incomplete /
    # 0-executed replay is NEVER a pass — nothing was exercised, so it cannot
    # certify anything. Subsumes the old per-step `errored` check.
    status="fail"; classification="other"
    reason="replay ${replay_status} (${steps_exec}/${steps_planned} steps): ${replay_reason}"
  elif [[ "$perf_sev" == "high" ]]; then
    status="fail"; classification="perf"; reason="perf severity HIGH (likely leak)"
  elif [[ "$struct_status" == "fail" ]]; then
    status="fail"; classification="visual-parity"; reason="structural-check FAIL"
  fi

  if [[ "$status" == "pass" ]]; then
    pass_count=$((pass_count + 1))
    echo "  [PASS] $journey (${steps_exec}/${steps_planned} steps)"
    continue
  fi

  fail_count=$((fail_count + 1))
  echo "  [FAIL] $journey — $reason"

  # Assemble evidence list (every finding needs >=1).
  evidence="$log_file"
  [[ -n "$crash_file" ]] && evidence="$evidence;$crash_file"
  [[ "$struct_status" == "fail" && -n "$struct_log" ]] && evidence="$evidence;$struct_log"

  sshot_arg=()
  if [[ -n "$screenshot" ]]; then
    # baseline side is filled by the RC-VISUAL stage; candidate side now.
    sshot_arg=(--screenshot-pair "|$screenshot")
  fi

  fid="${AREA_GROUP}-${DEVICE_CELL}-${journey}-$(printf '%03d' "$finding_count")"
  if python3 "$FINDINGS" append "$FINDINGS_CSV" \
       --id "$fid" --area "$AREA_GROUP" --device-cell "$DEVICE_CELL" \
       --classification "$classification" --evidence "$evidence" \
       --first-seen-commit "$FIRST_SEEN_COMMIT" "${sshot_arg[@]+"${sshot_arg[@]}"}"; then
    finding_count=$((finding_count + 1))
  else
    echo "  warn: failed to append finding for $journey (no evidence?)" >&2
  fi
done

echo ""
echo "=== area-worker summary ($AREA_GROUP / $DEVICE_CELL) ==="
echo "  passed:   $pass_count"
echo "  failed:   $fail_count"
echo "  skipped:  $skip_count"
echo "  findings: $finding_count → $FINDINGS_CSV"

if [[ $RUN_CHAOS -eq 1 ]]; then
  echo ""
  echo "--- chaos fan for area '$AREA_GROUP' ---"
  "$SCRIPT_DIR/regression-chaos-fan.sh" \
    --area-group "$AREA_GROUP" --device-cell "$DEVICE_CELL" \
    --run-dir "$RUN_DIR" --sim-id "$SIM_ID" --manifest "$MANIFEST" || true
fi

exit 0
