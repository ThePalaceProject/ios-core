#!/usr/bin/env bash
# Top-level orchestrator for the Palace iOS regression suite.
#
# Wraps existing scripts/regression-report.sh + scripts/simdrive-regress.sh +
# scripts/run-chaos-pass.sh + the new scripts/regression/* with proper phase
# ordering, auto-import of automated outputs into findings.csv, and a manual
# checklist generator. Does NOT replace the existing scripts — it composes them.
#
# Usage:
#   scripts/regression/regression-suite.sh \
#     --ticket PP-XXXX \
#     --baseline 3.0.0 --candidate 3.1.0 \
#     --candidate-app /path/to/Palace.app \
#     [--output-dir ~/Desktop/regression-PP-XXXX] \
#     [--skip-chaos] [--skip-side-by-side] [--mutation-real]
#
# Phases: 0=preflight, 1=setup, 2a=journey replay, 2b=auto sweep, 2c=chaos,
# 2d=side-by-side, 3=manual checklist generation, 5=report.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

TICKET=""
BASELINE=""
CANDIDATE=""
CANDIDATE_APP=""
OUTPUT_DIR=""
SKIP_CHAOS=0
SKIP_SBS=0
MUTATION_REAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket) TICKET="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --candidate) CANDIDATE="$2"; shift 2 ;;
    --candidate-app) CANDIDATE_APP="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-chaos) SKIP_CHAOS=1; shift ;;
    --skip-side-by-side) SKIP_SBS=1; shift ;;
    --mutation-real) MUTATION_REAL=1; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$TICKET" || -z "$BASELINE" || -z "$CANDIDATE" ]] && {
  echo "missing required: --ticket, --baseline, --candidate" >&2; exit 2;
}
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$HOME/Desktop/regression-$TICKET"

banner() { printf "\n\033[1;34m=== %s ===\033[0m\n" "$1"; }

# ---------- Phase 0: pre-flight ----------
banner "Phase 0 — Pre-flight (creds + devices + in-field signal)"
scripts/regression/preflight.sh \
  --output-dir "$OUTPUT_DIR" \
  --baseline-version "$BASELINE" || echo "[suite] pre-flight emitted soft-fail (continuing — gaps surfaced)"

# ---------- Phase 1: setup ----------
banner "Phase 1 — Setup workspace"
scripts/regression-report.sh setup --ticket "$TICKET" --output-dir "$OUTPUT_DIR" 2>&1 | tail -10

# ---------- Phase 2a: journey replay (candidate only) ----------
banner "Phase 2a — simdrive journey replay (candidate)"
SIM_UDID="$(xcrun simctl list devices iPhone 2>/dev/null | awk '/Booted/ {print $NF; exit}' | tr -d '()')"
[[ -z "$SIM_UDID" ]] && { echo "[suite] no booted iPhone sim — skip 2a"; }

if [[ -n "$SIM_UDID" ]]; then
  mkdir -p "$OUTPUT_DIR/automated/simdrive"
  SIMDRIVE_SIM_ID="$SIM_UDID" scripts/simdrive-regress.sh \
    --report "$OUTPUT_DIR/automated/simdrive/regress.json" 2>&1 | tail -15 || true
  python3 scripts/regression/import-simdrive.py \
    --regress-json "$OUTPUT_DIR/automated/simdrive/regress.json" \
    --findings-csv "$OUTPUT_DIR/findings.csv" \
    --pr "" --ticket "$TICKET"
fi

# ---------- Phase 2b: auto sweep ----------
banner "Phase 2b — Automated sweep (mutation surface + sync + push)"
AUTO_ARGS=(--output-dir "$OUTPUT_DIR" --baseline-ref "$BASELINE" --candidate-branch "$(git rev-parse --abbrev-ref HEAD)" --skip-sync-tests --skip-push)
[[ $MUTATION_REAL -eq 1 ]] && AUTO_ARGS+=(--mutation-run)
scripts/regression-report.sh auto "${AUTO_ARGS[@]}" 2>&1 | tail -25

# ---------- Phase 2c: chaos ----------
if [[ $SKIP_CHAOS -eq 0 ]]; then
  banner "Phase 2c — Chaos pass (diff-derived seeds, 15-minute cap)"
  if [[ -f "$OUTPUT_DIR/automated/mutation/changed-files.txt" && -n "$SIM_UDID" ]]; then
    scripts/run-chaos-pass.sh \
      --udid "$SIM_UDID" \
      --diff-files-from "$OUTPUT_DIR/automated/mutation/changed-files.txt" \
      --max-minutes 15 \
      --max-paths 20 2>&1 | tail -25 || echo "[suite] chaos pass returned non-zero (continuing)"
  else
    echo "[suite] skipped — no changed-files.txt or no booted sim"
  fi
else
  echo "[suite] Phase 2c skipped (--skip-chaos)"
fi

# ---------- Phase 2d: side-by-side ----------
if [[ $SKIP_SBS -eq 0 ]]; then
  banner "Phase 2d — Side-by-side (baseline $BASELINE vs candidate)"
  if [[ -n "$CANDIDATE_APP" && -d "$CANDIDATE_APP" ]]; then
    scripts/regression/side-by-side.sh \
      --baseline-ref "$BASELINE" \
      --candidate-app "$CANDIDATE_APP" \
      --output-dir "$OUTPUT_DIR" 2>&1 | tail -10 || echo "[suite] side-by-side returned non-zero (continuing)"
  else
    echo "[suite] skipped — no --candidate-app supplied or path missing"
  fi
else
  echo "[suite] Phase 2d skipped (--skip-side-by-side)"
fi

# ---------- Phase 3: manual checklist ----------
banner "Phase 3 — Manual checklist generation"
python3 scripts/regression/manual-checklist.py \
  --output-dir "$OUTPUT_DIR" \
  --baseline "$BASELINE" \
  --candidate "$CANDIDATE"

# ---------- Phase 5: HTML report (Phase 4 = human review of CSV, no script) ----------
banner "Phase 5 — Generate HTML report"
scripts/regression-report.sh report \
  --output-dir "$OUTPUT_DIR" \
  --baseline-version "$BASELINE" \
  --candidate-version "$CANDIDATE" 2>&1 | tail -10

# ---------- Summary ----------
banner "Regression suite complete"
cat <<EOF

Workspace: $OUTPUT_DIR

Inspect:
  preflight/creds-matrix.md
  preflight/devices.md
  preflight/MUST_TEST.md
  automated/simdrive/regress.json
  automated/mutation/summary.txt
  automated/side-by-side/diff.md   (if 2d ran)
  MANUAL_CHECKLIST.md
  findings.csv
  report/index.html

Next:
  1. Walk MANUAL_CHECKLIST.md with a human; log findings.
  2. Re-run \`scripts/regression-report.sh report --strict\` once findings are verified.
  3. Generate Jira tickets: \`scripts/regression-report.sh tickets --ticket $TICKET --dry-run\`.

EOF
exit 0
