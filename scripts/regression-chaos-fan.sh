#!/usr/bin/env bash
# regression-chaos-fan.sh — fan run-chaos-pass.sh across EVERY area-group.
#
# The campaign design (REGRESSION-REBUILD-DESIGN.md §4.4) requires chaos on
# every area, not just PR-diff-mapped seeds. This script reads each area-group's
# `chaos_seeds` from the manifest and invokes the existing chaos-qa orchestrator
# (`run-chaos-pass.sh`) per area, then ingests each run's findings into the
# campaign findings.csv (BUILD-PLAN schema) via scripts/regression_findings.py.
#
# The hard chaos rules are unchanged — they live in run-chaos-pass.sh and the
# chaos-qa subagent system prompt: Palace Bookshelf is the only borrow library,
# no `simctl erase`, no credential lockout, every finding requires log evidence
# from simdrive.logs. This script only orchestrates the fan + the ingest.
#
# Usage:
#   regression-chaos-fan.sh --run-dir <dir> [--area-group <g>] \
#       [--device-cell C-iphone-26] [--sim-id <UDID>] [--manifest <path>] \
#       [--max-paths N] [--max-minutes N] [--dry-run]
#
#   --run-dir      REQUIRED. Campaign run dir; chaos evidence nests under
#                  <run-dir>/chaos/<cell>/<area>/ and findings append to
#                  <run-dir>/findings.csv.
#   --area-group   Limit the fan to one group. Default: ALL groups in the manifest.
#   --device-cell  Cell tag for findings + dir paths. Default C-iphone-26.
#   --sim-id       Sim UDID. Default $HARNESS_SESSION_SIM_UDID, else first booted.
#   --manifest     Default .simdrive/regression-areas.yaml.
#   --max-paths    Per-area path budget passed to run-chaos-pass.sh (default 12).
#   --max-minutes  Per-area wall-clock budget (default 8).
#   --dry-run      Passed through to run-chaos-pass.sh (prints the prompt; no sim
#                  side effects). Use to verify wiring cheaply.
#
# Exit codes:
#   0 — fan completed (findings, if any, in findings.csv).
#   2 — config error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

MANIFEST=".simdrive/regression-areas.yaml"
FINDINGS="$SCRIPT_DIR/regression_findings.py"
CHAOS_PASS="$SCRIPT_DIR/run-chaos-pass.sh"

RUN_DIR=""
AREA_GROUP=""
DEVICE_CELL="C-iphone-26"
SIM_ID="${HARNESS_SESSION_SIM_UDID:-}"
MAX_PATHS=12
MAX_MINUTES=8
DRY_RUN=0

die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --area-group) AREA_GROUP="$2"; shift 2 ;;
    --device-cell) DEVICE_CELL="$2"; shift 2 ;;
    --sim-id) SIM_ID="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --max-paths) MAX_PATHS="$2"; shift 2 ;;
    --max-minutes) MAX_MINUTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_DIR" ]] || die "--run-dir is required"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
[[ -f "$CHAOS_PASS" ]] || die "run-chaos-pass.sh not found at $CHAOS_PASS"

if [[ -z "$SIM_ID" ]]; then
  SIM_ID="$(xcrun simctl list devices iPhone 2>/dev/null | grep Booted | head -1 | grep -oiE '[0-9a-f-]{36}' | head -1)"
  [[ -n "$SIM_ID" ]] || die "no --sim-id, no HARNESS_SESSION_SIM_UDID, no booted iPhone sim"
fi

# Which areas to fan.
if [[ -n "$AREA_GROUP" ]]; then
  AREAS=("$AREA_GROUP")
  python3 "$FINDINGS" chaos-seeds "$MANIFEST" "$AREA_GROUP" >/dev/null 2>&1 \
    || die "unknown area-group '$AREA_GROUP'"
else
  # Portable read loop (macOS bash 3.2 has no `mapfile`).
  AREAS=()
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && AREAS+=("$_line")
  done < <(python3 "$FINDINGS" areas "$MANIFEST")
fi

# Per-shard findings (palace-pm concurrency design): chaos writes each area's
# rows to <run-dir>/findings/<cell>__<area>.csv — the same shard the area-worker
# for that (cell,area) owns. Within a worker, chaos runs AFTER the journey pass
# (sequential), so they never race on the shard. RC-CAMPAIGN merges shards.
FINDINGS_DIR="$RUN_DIR/findings"
FIRST_SEEN_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
mkdir -p "$FINDINGS_DIR"

echo "=== regression-chaos-fan ==="
echo "areas:       ${AREAS[*]}"
echo "device-cell: $DEVICE_CELL"
echo "sim:         $SIM_ID"
echo "budget:      ${MAX_PATHS} paths / ${MAX_MINUTES} min per area"
echo "run-dir:     $RUN_DIR"
echo ""

total_ingested=0

for area in "${AREAS[@]}"; do
  SEEDS=()
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && SEEDS+=("$_line")
  done < <(python3 "$FINDINGS" chaos-seeds "$MANIFEST" "$area")
  if [[ ${#SEEDS[@]} -eq 0 ]]; then
    SEEDS=(cold-launch)
  fi

  # Nest the chaos run under the campaign tree so its evidence is co-located.
  area_chaos_root="$RUN_DIR/chaos/$DEVICE_CELL/$area"
  mkdir -p "$area_chaos_root"

  seed_args=()
  for s in "${SEEDS[@]}"; do seed_args+=(--seed "$s"); done

  echo "--- chaos: area '$area' (seeds: ${SEEDS[*]}) ---"
  dry_arg=()
  [[ $DRY_RUN -eq 1 ]] && dry_arg=(--dry-run)

  # run-chaos-pass.sh writes to $CHAOS_RUNS_ROOT/<timestamp>/.
  # bash 3.2 throws on "${empty[@]}" under set -u — guard with the [@]+ idiom.
  CHAOS_RUNS_ROOT="$area_chaos_root" "$CHAOS_PASS" \
    --udid "$SIM_ID" "${seed_args[@]+"${seed_args[@]}"}" \
    --max-paths "$MAX_PATHS" --max-minutes "$MAX_MINUTES" \
    "${dry_arg[@]+"${dry_arg[@]}"}" 2>&1 | sed 's/^/    /' || true

  if [[ $DRY_RUN -eq 1 ]]; then
    # Dry-run produced a prompt.txt under the timestamp dir — that's the wiring
    # evidence. Nothing to ingest.
    latest="$(ls -dt "$area_chaos_root"/*/ 2>/dev/null | head -1)"
    [[ -n "$latest" ]] && echo "    [dry-run] prompt at ${latest}prompt.txt"
    continue
  fi

  # Find the run dir this pass produced (most recent timestamp dir).
  latest="$(ls -dt "$area_chaos_root"/*/ 2>/dev/null | head -1)"
  if [[ -z "$latest" ]]; then
    echo "    warn: no chaos run dir produced for area '$area'" >&2
    continue
  fi
  chaos_csv="${latest}findings.csv"

  # Ingest legacy chaos rows → campaign schema (reuse the shared writer),
  # targeting THIS area's shard.
  area_shard="$FINDINGS_DIR/${DEVICE_CELL}__${area}.csv"
  ingested="$(AREA="$area" DEVICE_CELL="$DEVICE_CELL" CHAOS_RUN_DIR="$latest" \
    CHAOS_CSV="$chaos_csv" CAMPAIGN_CSV="$area_shard" \
    FIRST_SEEN_COMMIT="$FIRST_SEEN_COMMIT" SCRIPT_DIR="$SCRIPT_DIR" \
    python3 - <<'PYEOF'
import csv, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["SCRIPT_DIR"])
from regression_findings import append_finding, translate_chaos_row

area = os.environ["AREA"]
cell = os.environ["DEVICE_CELL"]
run_dir = Path(os.environ["CHAOS_RUN_DIR"])
chaos_csv = Path(os.environ["CHAOS_CSV"])
campaign_csv = os.environ["CAMPAIGN_CSV"]
commit = os.environ["FIRST_SEEN_COMMIT"]

if not chaos_csv.exists():
    print(0); sys.exit(0)

# Evidence common to this area chaos run (log-evidence required rule).
run_evidence = [str(chaos_csv)]
for name in ("stderr.log", "summary.json", "summary.txt", "prompt.txt"):
    p = run_dir / name
    if p.exists():
        run_evidence.append(str(p))
replays = run_dir / "replays"
if replays.is_dir():
    for y in sorted(replays.glob("*.yaml")):
        run_evidence.append(str(y))

# Translation + anti-hallucination discard live in the tested module
# (translate_chaos_row + the require_evidence check in append_finding). This is just
# the iteration + id assignment + count.
n = 0
with chaos_csv.open(newline="") as f:
    for i, row in enumerate(csv.DictReader(f)):
        finding = translate_chaos_row(
            row, finding_id=f"chaos-{area}-{cell}-{i:03d}",
            area=area, device_cell=cell, run_evidence=run_evidence,
            first_seen_commit=commit,
        )
        if finding is None:
            continue
        try:
            append_finding(campaign_csv, finding)
            n += 1
        except ValueError:
            # No evidence at all — discard (anti-hallucination).
            pass
print(n)
PYEOF
)"
  echo "    ingested $ingested chaos finding(s) for area '$area'"
  total_ingested=$((total_ingested + ${ingested:-0}))
done

echo ""
echo "=== chaos-fan summary ==="
echo "  areas fanned:      ${#AREAS[@]}"
echo "  findings ingested: $total_ingested → $FINDINGS_DIR/${DEVICE_CELL}__<area>.csv"
exit 0
