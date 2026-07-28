#!/usr/bin/env bash
#
# run-tier.sh — execute a verification tier defined in scripts/verify-tiers.json.
#
# The manifest is the single source of truth for WHAT each tier runs (and which
# CI job each gate mirrors). This runner INTERPRETS the manifest — it does not
# hardcode the gate list. Adding a MetaTests class or a detector to the manifest
# automatically changes what this runner executes.
#
# USAGE
#   scripts/run-tier.sh T1                 # fast parity (pre-push / tooling-diff bar)
#   scripts/run-tier.sh T0                 # iteration spot-check (NEVER attestable)
#   scripts/run-tier.sh T2                 # full CI-identical parity (delegates)
#   scripts/run-tier.sh T3                 # starvation parity (delegates)
#
# ENV
#   HARNESS_SESSION_SIM_UDID   destination sim UDID (else first booted iPhone).
#   TIER_DERIVED_DATA          derivedDataPath (default ~/…/DerivedData/Palace-tier).
#   TIER_ONLY_TESTING          T0 only: space-separated class names to spot-check.
#   TIER_BASE                  diff base for diff-scoped gates (default: auto-detect).
#
# EXIT
#   0  all blocking gates passed (warnings allowed)
#   1  at least one blocking gate failed
#   2  usage / manifest error
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
MANIFEST="scripts/verify-tiers.json"

TIER="${1:-}"
case "$TIER" in
  T0|T1|T2|T3) ;;
  *) echo "usage: $0 <T0|T1|T2|T3>" >&2; exit 2 ;;
esac
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 2; }

# ---- shared resolution ------------------------------------------------------
detect_base_branch() {
  local c
  for c in origin/develop origin/main origin/master; do
    if git rev-parse --verify "$c" &>/dev/null; then echo "$c"; return; fi
  done
  echo "HEAD~10"
}
BASE="${TIER_BASE:-$(detect_base_branch)}"
DERIVED_DATA="${TIER_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Palace-tier}"

resolve_sim() {
  if [ -n "${HARNESS_SESSION_SIM_UDID:-}" ]; then echo "$HARNESS_SESSION_SIM_UDID"; return; fi
  # first booted iPhone; else first available iPhone.
  local id
  id=$(xcrun simctl list devices booted 2>/dev/null | grep -Eo '\(([0-9A-F-]{36})\)' | tr -d '()' | head -1)
  [ -z "$id" ] && id=$(xcrun simctl list devices available 2>/dev/null | grep -i iphone | grep -Eo '\(([0-9A-F-]{36})\)' | tr -d '()' | head -1)
  echo "$id"
}

# ---- per-gate result recording ---------------------------------------------
PASS=0; FAIL=0; WARN=0; SKIP=0
declare -a ROWS
rec() { # rec <status> <id> <detail>
  local st="$1" id="$2" detail="$3" sym
  case "$st" in
    pass) PASS=$((PASS+1)); sym="PASS" ;;
    fail) FAIL=$((FAIL+1)); sym="FAIL" ;;
    warn) WARN=$((WARN+1)); sym="WARN" ;;
    skip) SKIP=$((SKIP+1)); sym="SKIP" ;;
  esac
  printf '  [%-4s] %-38s %s\n' "$sym" "$id" "$detail"
  ROWS+=("$sym|$id|$detail")
}

# python helper: emit gate rows for a tier as TSV: id \t kind \t blocking \t <json>
gate_json() { python3 - "$MANIFEST" "$TIER" <<'PY'
import json, sys
manifest, tier = sys.argv[1], sys.argv[2]
d = json.load(open(manifest))
t = d["tiers"][tier]
for g in t["gates"]:
    print("\t".join([g.get("id","?"), g.get("kind","?"),
                     "1" if g.get("blocking", True) else "0", json.dumps(g)]))
PY
}
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"; }
field_list() { python3 -c 'import json,sys; print(" ".join(json.loads(sys.argv[1]).get(sys.argv[2],[])))' "$1" "$2"; }

TIER_ATTESTABLE=$(python3 -c 'import json,sys; print("1" if json.load(open(sys.argv[1]))["tiers"][sys.argv[2]].get("attestable") else "0")' "$MANIFEST" "$TIER")
TIER_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tiers"][sys.argv[2]].get("name",""))' "$MANIFEST" "$TIER")

echo "=============================================================="
echo " run-tier $TIER — $TIER_NAME"
echo " base=$BASE  derivedData=$DERIVED_DATA"
echo "=============================================================="

# ---- gate executors ---------------------------------------------------------
diff_file() { local f; f=$(mktemp -t tier-diff.XXXX); git diff "$BASE"...HEAD > "$f" 2>/dev/null || true; echo "$f"; }

run_build_for_testing() {
  local gj="$1" id="$2" scheme project
  scheme=$(field "$gj" scheme); project=$(field "$gj" project)
  local sim; sim=$(resolve_sim)
  if [ -z "$sim" ]; then rec fail "$id" "no simulator resolved"; return 1; fi
  local log; log=$(mktemp -t tier-bft.XXXX)
  if xcodebuild build-for-testing -project "$project" -scheme "$scheme" \
       -destination "id=$sim" -derivedDataPath "$DERIVED_DATA" > "$log" 2>&1; then
    rec pass "$id" "build-for-testing OK (sim ${sim:0:8})"; rm -f "$log"; return 0
  else
    rec fail "$id" "build-for-testing FAILED — see $log"; tail -15 "$log"; return 1
  fi
}

run_xctest_classes() {
  local gj="$1" id="$2" classes run_via
  run_via=$(field "$gj" run_via)
  classes=$(field_list "$gj" classes)
  # T0 override
  if [ "$TIER" = "T0" ] && [ -n "${TIER_ONLY_TESTING:-}" ]; then classes="$TIER_ONLY_TESTING"; fi
  if [ -z "$classes" ]; then rec skip "$id" "no classes (supply TIER_ONLY_TESTING for T0)"; return 0; fi
  local sim; sim=$(resolve_sim)
  if [ -z "$sim" ]; then rec fail "$id" "no simulator resolved"; return 1; fi
  local -a only=(); local c
  for c in $classes; do only+=("-only-testing:PalaceTests/$c"); done
  local action="test"; [ "$run_via" = "test-without-building" ] && action="test-without-building"
  local log; log=$(mktemp -t tier-xctest.XXXX)
  xcodebuild "$action" -project Palace.xcodeproj -scheme Palace \
    -destination "id=$sim" -derivedDataPath "$DERIVED_DATA" "${only[@]}" > "$log" 2>&1
  local ex=$?
  local roll; roll=$(grep -E "Test Suite '(Selected|All) tests'" "$log" | tail -1)
  if [ "$ex" -eq 0 ]; then
    rec pass "$id" "$(echo "$classes" | wc -w | tr -d ' ') classes green"
    rm -f "$log"; return 0
  else
    rec fail "$id" "$(grep -E 'error: -\[.*\]|failed - ' "$log" | head -1 | cut -c1-120)"
    echo "      log: $log"
    return 1
  fi
}

run_detector() {
  local gj="$1" id="$2" script scan mode
  script=$(field "$gj" detector_script); scan=$(field "$gj" scan_mode); mode=$(field "$gj" mode)
  if [ ! -f "scripts/$script" ]; then rec skip "$id" "scripts/$script not found"; return 0; fi
  local out ex
  if [ "$scan" = "scan" ]; then
    out=$(python3 "scripts/$script" --quiet 2>&1); ex=$?
  elif [ "$scan" = "none" ]; then
    out=$(python3 "scripts/$script" 2>&1); ex=$?
  else
    local d; d=$(diff_file)
    out=$(python3 "scripts/$script" --diff "$d" --quiet 2>&1); ex=$?
    rm -f "$d"
  fi
  if [ "$ex" -eq 0 ]; then rec pass "$id" "clean"; return 0
  elif [ "$mode" = "warn" ]; then rec warn "$id" "$(echo "$out" | head -1) (non-blocking)"; return 0
  else rec fail "$id" "$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-140)"; return 1; fi
}

run_lint_test_quality() {
  local gj="$1" id="$2" script; script=$(field "$gj" script)
  if [ ! -f "scripts/$script" ]; then rec skip "$id" "scripts/$script not found"; return 0; fi
  local changed per new=0 f
  changed=$(git diff --name-only "$BASE"...HEAD -- '*.swift' 2>/dev/null | grep 'Tests/' || true)
  per=$(python3 "scripts/$script" --per-file 2>&1 || true)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local n; n=$(echo "$per" | grep -E "^$f:[0-9]+:(FLAKE|FLUFF|MISSING|TIMEOUT)-" | wc -l | tr -d ' ')
    new=$((new+n))
  done <<< "$changed"
  if [ "$new" -eq 0 ]; then rec pass "$id" "0 blocking violations in changed test files"; return 0
  else rec fail "$id" "$new blocking violations in changed test files"; return 1; fi
}

run_script_diff() {
  local gj="$1" id="$2" script; script=$(field "$gj" script)
  if [ ! -f "scripts/$script" ]; then rec skip "$id" "scripts/$script not found"; return 0; fi
  local d out ex; d=$(diff_file)
  out=$(bash "scripts/$script" "$d" 2>&1); ex=$?
  rm -f "$d"
  if [ "$ex" -eq 0 ]; then rec pass "$id" "clean"; return 0
  else rec fail "$id" "$(echo "$out" | grep -m1 -i block || echo "$out" | head -1)"; return 1; fi
}

run_stanza() {
  local gj="$1" id="$2" hook; hook=$(field "$gj" hook)
  hook="${hook/#\~/$HOME}"
  if [ ! -f "$hook" ]; then rec skip "$id" "stanza hook absent (self-disabling for contributors)"; return 0; fi
  local msg out ex; msg=$(mktemp -t tier-msg.XXXX)
  git log -1 --format=%B HEAD > "$msg" 2>/dev/null || echo "" > "$msg"
  out=$(bash "$hook" "$msg" 2>&1); ex=$?
  rm -f "$msg"
  if [ "$ex" -eq 0 ]; then rec pass "$id" "HEAD commit stanza OK"; return 0
  else rec fail "$id" "$(echo "$out" | head -2 | tr '\n' ' ')"; return 1; fi
}

run_bash_n() {
  local id="$1" fail=0 f
  while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || { echo "      bash -n FAIL: $f"; fail=1; }
  done < <(find scripts -type f -name '*.sh' 2>/dev/null | sort)
  if [ "$fail" -eq 0 ]; then rec pass "$id" "all committed shell scripts parse"; return 0
  else rec fail "$id" "one or more shell scripts have a syntax error"; return 1; fi
}

run_pytest() {
  local gj="$1" id="$2" path; path=$(field "$gj" path)
  if [ ! -d "$path" ]; then rec skip "$id" "$path not found"; return 0; fi
  local log; log=$(mktemp -t tier-pytest.XXXX)
  if python3 -m pytest "$path" -q > "$log" 2>&1; then
    rec pass "$id" "$(grep -Eo '[0-9]+ passed[^,]*' "$log" | tail -1)"; rm -f "$log"; return 0
  else
    rec fail "$id" "$(grep -Eo '[0-9]+ failed[^,]*' "$log" | tail -1 || echo 'pytest failed')"
    echo "      log: $log"; return 1
  fi
}

run_delegate() {
  local gj="$1" id="$2"
  local -a cmd; mapfile -t cmd < <(python3 -c 'import json,sys; [print(x) for x in json.loads(sys.argv[1]).get("cmd",[])]' "$gj")
  if [ ! -f "${cmd[0]}" ]; then rec skip "$id" "${cmd[0]} not found"; return 0; fi
  echo "  → delegating to: ${cmd[*]}"
  if "${cmd[@]}"; then rec pass "$id" "${cmd[*]} succeeded"; return 0
  else rec fail "$id" "${cmd[*]} failed"; return 1; fi
}

# ---- main loop --------------------------------------------------------------
OVERALL=0
while IFS=$'\t' read -r gid gkind gblock gj; do
  [ -z "$gid" ] && continue
  case "$gkind" in
    xcodebuild-build-for-testing) run_build_for_testing "$gj" "$gid" || OVERALL=1 ;;
    xctest-classes)               run_xctest_classes "$gj" "$gid" || OVERALL=1 ;;
    detector)                     run_detector "$gj" "$gid" || OVERALL=1 ;;
    lint-test-quality)            run_lint_test_quality "$gj" "$gid" || OVERALL=1 ;;
    script-diff)                  run_script_diff "$gj" "$gid" || OVERALL=1 ;;
    stanza)                       run_stanza "$gj" "$gid" || OVERALL=1 ;;
    bash-n)                       run_bash_n "$gid" || OVERALL=1 ;;
    pytest)                       run_pytest "$gj" "$gid" || OVERALL=1 ;;
    delegate)                     run_delegate "$gj" "$gid" || OVERALL=1 ;;
    *)                            rec skip "$gid" "unknown kind: $gkind" ;;
  esac
done < <(gate_json)

echo "--------------------------------------------------------------"
echo " ROLLUP $TIER: PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP"
if [ "$OVERALL" -eq 0 ]; then
  if [ "$TIER_ATTESTABLE" = "1" ]; then
    echo " RESULT: GREEN — $TIER gates passed. Attestable as '$TIER $TIER_NAME' parity."
  else
    echo " RESULT: GREEN (gates passed) — but $TIER is NEVER-ATTESTABLE."
    echo "         A green $TIER is a scoped spot-check, NOT a full or green pass."
    echo "         (CLAUDE.md build-&-test rule; incident PP-4542.)"
  fi
else
  echo " RESULT: RED — a blocking $TIER gate failed. Not shippable."
fi
echo "=============================================================="
exit "$OVERALL"
