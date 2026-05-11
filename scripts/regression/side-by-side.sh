#!/usr/bin/env bash
# Phase 2d of the regression suite: dual-install + journey diff.
#
# Resolves --baseline-ref to a tag, builds the baseline Palace.app (cached),
# boots a second sim, installs baseline on sim-A and candidate on sim-B,
# runs scripts/simdrive-regress.sh on both, diffs the regress.json fragments.
#
# Skips gracefully if the second sim can't be allocated or the build fails.
#
# Usage:
#   scripts/regression/side-by-side.sh \
#     --baseline-ref 3.0.0 \
#     --candidate-app /tmp/regression-3.1.0/dd/Build/Products/Debug-iphonesimulator/Palace.app \
#     --output-dir ~/Desktop/regression-PP-XXXX \
#     [--sim-a UDID-baseline] [--sim-b UDID-candidate]
#
# Output: <output-dir>/automated/side-by-side/
#   baseline.regress.json   — simdrive-regress JSON for baseline
#   candidate.regress.json  — simdrive-regress JSON for candidate
#   diff.json               — per-journey side-by-side classification
#   diff.md                 — human-readable summary
#
# Exit:
#   0 — diff produced (regardless of pass/fail of individual journeys)
#   1 — could not produce a baseline build or boot a second sim
#   2 — config error
set -uo pipefail

BASELINE_REF=""
CANDIDATE_APP=""
OUTPUT_DIR=""
SIM_A=""
SIM_B=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-ref) BASELINE_REF="$2"; shift 2 ;;
    --candidate-app) CANDIDATE_APP="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --sim-a) SIM_A="$2"; shift 2 ;;
    --sim-b) SIM_B="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$BASELINE_REF" || -z "$OUTPUT_DIR" ]] && { echo "missing --baseline-ref or --output-dir" >&2; exit 2; }
[[ -z "$CANDIDATE_APP" || ! -d "$CANDIDATE_APP" ]] && { echo "missing or non-existent --candidate-app: $CANDIDATE_APP" >&2; exit 2; }

OUT="$OUTPUT_DIR/automated/side-by-side"
mkdir -p "$OUT"

# Resolve sim B (candidate). Default: any iPhone 16 Pro that's NOT sim-A.
if [[ -z "$SIM_B" ]]; then
  SIM_B="$(xcrun simctl list devices iPhone 2>/dev/null | awk '/Booted/ {print $(NF-1); exit}' | tr -d '()')"
fi

# Resolve sim A (baseline). If not provided, find a SECOND booted sim.
if [[ -z "$SIM_A" ]]; then
  SIM_A="$(xcrun simctl list devices iPhone 2>/dev/null | awk '/Booted/ {print $(NF-1)}' | tr -d '()' | grep -v "^${SIM_B}$" | head -1)"
fi
if [[ -z "$SIM_A" ]]; then
  echo "[side-by-side] cannot find a 2nd booted sim for baseline. Boot one with:" >&2
  echo "    xcrun simctl create baseline-sim 'iPhone 16 Pro' iOS18.4 && xcrun simctl boot <UDID>" >&2
  echo "  or pass --sim-a UDID. Skipping side-by-side." >&2
  exit 1
fi

echo "[side-by-side] sim-A (baseline $BASELINE_REF) = $SIM_A"
echo "[side-by-side] sim-B (candidate)               = $SIM_B"

# Determine cache key for baseline build
BASELINE_CACHE_DIR="/tmp/regression-baseline-$BASELINE_REF/dd"
BASELINE_APP="$BASELINE_CACHE_DIR/Build/Products/Debug-iphonesimulator/Palace.app"

if [[ -d "$BASELINE_APP" ]]; then
  echo "[side-by-side] baseline build cached at $BASELINE_APP"
else
  echo "[side-by-side] baseline build not cached — building $BASELINE_REF"
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  STASHED=0
  if ! git diff --quiet || ! git diff --cached --quiet; then
    git stash push -u -m "side-by-side autostash" >/dev/null && STASHED=1
  fi
  trap 'git checkout "$CURRENT_BRANCH" >/dev/null 2>&1; [[ $STASHED -eq 1 ]] && git stash pop >/dev/null 2>&1; true' EXIT

  if ! git checkout "$BASELINE_REF" >/dev/null 2>&1; then
    echo "[side-by-side] cannot checkout $BASELINE_REF — does the tag/branch exist locally?" >&2
    exit 1
  fi

  mkdir -p "$BASELINE_CACHE_DIR"
  if ! xcodebuild -project Palace.xcodeproj -scheme Palace \
        -destination "platform=iOS Simulator,id=$SIM_B" \
        -derivedDataPath "$BASELINE_CACHE_DIR" \
        build 2>&1 | tail -3; then
    echo "[side-by-side] baseline build failed" >&2
    exit 1
  fi
  git checkout "$CURRENT_BRANCH" >/dev/null 2>&1
  [[ $STASHED -eq 1 ]] && git stash pop >/dev/null 2>&1
  trap - EXIT
fi

# Install on each sim
echo "[side-by-side] installing baseline on $SIM_A …"
xcrun simctl uninstall "$SIM_A" org.thepalaceproject.palace 2>/dev/null || true
xcrun simctl install "$SIM_A" "$BASELINE_APP"

echo "[side-by-side] installing candidate on $SIM_B …"
xcrun simctl uninstall "$SIM_B" org.thepalaceproject.palace 2>/dev/null || true
xcrun simctl install "$SIM_B" "$CANDIDATE_APP"

# Run journey corpus on each
echo "[side-by-side] simdrive-regress against baseline (sim-A) …"
SIMDRIVE_SIM_ID="$SIM_A" scripts/simdrive-regress.sh \
  --report "$OUT/baseline.regress.json" 2>&1 | tail -10 || true

echo "[side-by-side] simdrive-regress against candidate (sim-B) …"
SIMDRIVE_SIM_ID="$SIM_B" scripts/simdrive-regress.sh \
  --report "$OUT/candidate.regress.json" 2>&1 | tail -10 || true

# Diff
python3 - <<PY > "$OUT/diff.json"
import json, sys
from pathlib import Path
out = Path("$OUT")
b = json.loads((out / "baseline.regress.json").read_text())
c = json.loads((out / "candidate.regress.json").read_text())
by_journey = {j["journey"]: j for j in b.get("journeys", [])}
diff = {"baseline_ref": "$BASELINE_REF", "journeys": []}
for cj in c.get("journeys", []):
    bj = by_journey.get(cj["journey"], {})
    bs = bj.get("status", "missing")
    cs = cj.get("status", "missing")
    klass = "no-change"
    if bs == "pass" and cs == "fail":
        klass = "regression"
    elif bs == "fail" and cs == "pass":
        klass = "fixed"
    elif bs == "fail" and cs == "fail":
        klass = "pending-investigation"  # both broken — likely infra
    elif bs == "skip" or cs == "skip":
        klass = "skip"
    diff["journeys"].append({
        "journey": cj["journey"],
        "baseline_status": bs,
        "candidate_status": cs,
        "classification": klass,
        "baseline_detail": bj.get("detail"),
        "candidate_detail": cj.get("detail"),
    })
print(json.dumps(diff, indent=2))
PY

# Render
python3 - <<PY > "$OUT/diff.md"
import json
from pathlib import Path
d = json.loads(Path("$OUT/diff.json").read_text())
print(f"# Side-by-side: baseline={d['baseline_ref']} vs candidate\n")
print("| Journey | Baseline | Candidate | Classification |")
print("|---|---|---|---|")
for j in d["journeys"]:
    print(f"| {j['journey']} | {j['baseline_status']} | {j['candidate_status']} | **{j['classification']}** |")
print("\n## Notable diffs")
for j in d["journeys"]:
    if j["classification"] in ("regression", "fixed"):
        print(f"\n### {j['journey']} — {j['classification']}")
        print(f"- Baseline: {j['baseline_detail']}")
        print(f"- Candidate: {j['candidate_detail']}")
PY

echo "[side-by-side] artifacts:"
echo "  $OUT/baseline.regress.json"
echo "  $OUT/candidate.regress.json"
echo "  $OUT/diff.json"
echo "  $OUT/diff.md"
exit 0
