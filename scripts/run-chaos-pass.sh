#!/usr/bin/env bash
# run-chaos-pass.sh — orchestrator for the chaos-qa subagent.
#
# Reads PR-diff inputs (or accepts an explicit seed list), prepares the
# simulator, allocates a fresh chaos-runs directory, then invokes the
# chaos-qa subagent via Claude Code's headless mode (`claude -p`).
#
# Designed to run from CI (GitHub Actions self-hosted Mac) OR locally for
# dogfooding. Output: a per-session directory under ~/.simdrive/chaos-runs/
# containing findings.csv, replays/, and a summary.json.
#
# Usage:
#     # On-demand against a PR's changed files:
#     run-chaos-pass.sh --diff-files-from /tmp/changed-files.txt --udid <UDID>
#
#     # Nightly against develop with all flows:
#     run-chaos-pass.sh --all-flows --udid <UDID>
#
#     # Explicit seeds + budget overrides:
#     run-chaos-pass.sh --seed anonymous-borrow/06-my-books --max-paths 20 --max-minutes 10 --udid <UDID>
#
# Constraints (passed through to the subagent):
#     --max-paths    Hard cap on adversarial paths explored (default: 30)
#     --max-minutes  Hard cap on wall-clock minutes (default: 15)
#
# Exit codes:
#     0 — completed successfully (findings may or may not be present)
#     1 — argument or environment error
#     2 — subagent failed to start or returned non-zero
#     3 — simulator state setup failed

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_ROOT="${CHAOS_RUNS_ROOT:-$HOME/.simdrive/chaos-runs}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

UDID=""
MAX_PATHS=30
MAX_MINUTES=15
DIFF_FILES_FROM=""
SEEDS=()
ALL_FLOWS=0
DRY_RUN=0
APP_PATH=""
PRE_SEED_DEFAULTS=""
PRISTINE=0

usage() {
    cat <<EOF
run-chaos-pass.sh — invoke the chaos-qa subagent for an iOS regression pass.

Required:
    --udid <UDID>             Simulator UDID with Palace.app installed.

Seed selection (pick one):
    --diff-files-from <PATH>  File with one changed-file path per line.
                              Seeds are derived via scripts/chaos-targets.py.
    --all-flows               Use every captured flow as a seed.
    --seed <flow/step>        Explicit seed. Repeatable.

Optional:
    --app-path <PATH>         Palace.app path (only needed for cold-launch
                              reset; can omit if the app is already installed).
    --max-paths <N>           Hard cap on paths (default: 30).
    --max-minutes <N>         Hard cap on wall-clock minutes (default: 15).
    --pre-seed-defaults <PATH>
                              Path to a JSON file with pre-launch UserDefaults
                              writes. Each top-level key is a defaults key,
                              each value is the value to write. Applied via
                              \`xcrun simctl spawn defaults write\` BEFORE the
                              session starts — lets chaos exercise edge-case
                              account / registry / settings state that's
                              hard to reach via the UI. Use to kill internal
                              mutants the UI surface doesn't expose (e.g.
                              AccountsManager L308/L613/L668-class predicates).
    --pristine                Force fresh install: uninstall the app + clear
                              UserDefaults + reinstall before launching. Useful
                              when prior session state would interfere with
                              the seed.
    --dry-run                 Print the prompt that would be sent and exit.
    --help                    This message.

Output:
    A run directory under \$CHAOS_RUNS_ROOT/<timestamp>/ containing:
        findings.csv     CSV rows in the regression-report format
        replays/         simdrive replay YAMLs for any worth-keeping paths
        summary.json     final summary from the subagent
        prompt.txt       the prompt sent to chaos-qa (for reproducibility)
EOF
}

while (( "$#" )); do
    case "$1" in
        --udid) UDID="$2"; shift 2 ;;
        --diff-files-from) DIFF_FILES_FROM="$2"; shift 2 ;;
        --all-flows) ALL_FLOWS=1; shift ;;
        --seed) SEEDS+=("$2"); shift 2 ;;
        --max-paths) MAX_PATHS="$2"; shift 2 ;;
        --max-minutes) MAX_MINUTES="$2"; shift 2 ;;
        --app-path) APP_PATH="$2"; shift 2 ;;
        --pre-seed-defaults) PRE_SEED_DEFAULTS="$2"; shift 2 ;;
        --pristine) PRISTINE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$UDID" ]]; then
    echo "error: --udid is required" >&2
    exit 1
fi

# Derive seeds.
if [[ -n "$DIFF_FILES_FROM" ]]; then
    if [[ ! -f "$DIFF_FILES_FROM" ]]; then
        echo "error: --diff-files-from path not found: $DIFF_FILES_FROM" >&2
        exit 1
    fi
    derived=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && derived+=("$line")
    done < <(
        cat "$DIFF_FILES_FROM" | tr '\n' '\0' | xargs -0 python3 "$REPO_ROOT/scripts/chaos-targets.py" \
            --fixtures-root "$REPO_ROOT/.simdrive/fixtures"
    )
    SEEDS+=("${derived[@]}")
elif (( ALL_FLOWS )); then
    derived=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && derived+=("$line")
    done < <(python3 "$REPO_ROOT/scripts/chaos-targets.py" \
        --all --fixtures-root "$REPO_ROOT/.simdrive/fixtures")
    SEEDS+=("${derived[@]}")
fi

if (( ${#SEEDS[@]} == 0 )); then
    SEEDS=(cold-launch)
    echo "info: no seeds derived from inputs; falling back to cold-launch" >&2
fi

# Per-seed budget split (so multiple seeds share the global budget fairly).
PATHS_PER_SEED=$(( MAX_PATHS / ${#SEEDS[@]} ))
(( PATHS_PER_SEED < 3 )) && PATHS_PER_SEED=3
MINUTES_PER_SEED=$(( MAX_MINUTES / ${#SEEDS[@]} ))
(( MINUTES_PER_SEED < 2 )) && MINUTES_PER_SEED=2

# Run dir.
RUN_DIR="$RUNS_ROOT/$TIMESTAMP"
mkdir -p "$RUN_DIR/replays"
FINDINGS_CSV="$RUN_DIR/findings.csv"
PROMPT_FILE="$RUN_DIR/prompt.txt"

# CSV header (so the file is valid even if no findings emitted).
cat > "$FINDINGS_CSV" <<'CSV'
ID,Title,Area,Test ID,Classification,Severity,Verified,Baseline Behavior,Candidate Behavior,Steps,Screenshot Baseline,Screenshot Candidate,Notes,PR,Jira Ticket
CSV

# Pre-launch state injection. Skip during dry-run — these have real side
# effects on the simulator's UserDefaults / app install state.
PRE_LAUNCH_STEPS=""
if (( DRY_RUN )); then
    [[ -n "$PRE_SEED_DEFAULTS" ]] && PRE_LAUNCH_STEPS+="info: would apply pre_seed_defaults from $PRE_SEED_DEFAULTS\n"
    (( PRISTINE )) && PRE_LAUNCH_STEPS+="info: would reinstall app (pristine mode)\n"
elif (( PRISTINE )); then
    PRE_LAUNCH_STEPS+="info: pristine mode — uninstall + reinstall\n"
    if [[ -n "$APP_PATH" && -d "$APP_PATH" ]]; then
        xcrun simctl uninstall "$UDID" org.thepalaceproject.palace 2>&1 | tail -1 || true
        xcrun simctl install "$UDID" "$APP_PATH" >&2
    else
        echo "warn: --pristine requested without valid --app-path; skipping reinstall" >&2
    fi
fi

if [[ -n "$PRE_SEED_DEFAULTS" ]]; then
    if [[ ! -f "$PRE_SEED_DEFAULTS" ]]; then
        echo "error: --pre-seed-defaults path not found: $PRE_SEED_DEFAULTS" >&2
        exit 1
    fi
    # Each top-level key in the JSON becomes a `defaults write` call. Values are
    # written as JSON-encoded strings — chaos tests typically inject corrupted
    # plist blobs as base64 or as raw JSON.
    PRE_LAUNCH_STEPS+="info: applying pre_seed_defaults from $PRE_SEED_DEFAULTS\n"
    python3 -c '
import json, subprocess, sys
udid = sys.argv[1]
path = sys.argv[2]
data = json.load(open(path))
for key, value in data.items():
    if isinstance(value, (dict, list)):
        # Write as a JSON string — caller may want to round-trip via PropertyList.
        encoded = json.dumps(value)
    else:
        encoded = str(value)
    cmd = ["xcrun", "simctl", "spawn", udid, "defaults", "write",
           "org.thepalaceproject.palace", key, encoded]
    print("  pre-seed:", key, "=", encoded[:80] + ("..." if len(encoded) > 80 else ""), file=sys.stderr)
    subprocess.run(cmd, check=False)
' "$UDID" "$PRE_SEED_DEFAULTS"
fi

# Build the chaos-qa prompt.
{
    echo "Run an adversarial chaos QA pass on the Palace iOS simulator."
    echo
    echo "Inputs:"
    echo "  udid: $UDID"
    [[ -n "$APP_PATH" ]] && echo "  app_path: $APP_PATH"
    echo "  budget: max ${MAX_PATHS} paths AND max ${MAX_MINUTES} wall-clock minutes (whichever first)"
    echo "  per_seed_budget: ${PATHS_PER_SEED} paths / ${MINUTES_PER_SEED} minutes"
    echo "  findings_csv: $FINDINGS_CSV"
    echo "  replays_dir: $RUN_DIR/replays"
    [[ -n "$PRE_SEED_DEFAULTS" ]] && echo "  pre_seed_defaults: $PRE_SEED_DEFAULTS (already applied)"
    (( PRISTINE )) && echo "  pristine: yes (app reinstalled before launch)"
    echo
    echo "Seeds (process in order, share budget evenly):"
    for s in "${SEEDS[@]}"; do echo "  - $s"; done
    echo
    if [[ -n "$DIFF_FILES_FROM" ]]; then
        echo "Focus (PR-changed files; bias exploration toward strategies most"
        echo "likely to surface regressions in these areas):"
        sed 's/^/  - /' "$DIFF_FILES_FROM"
    fi
    echo
    echo "Constraints:"
    echo "  - Palace Bookshelf is the only library you may borrow from."
    echo "  - No simctl erase. Reset state via uninstall+install only."
    if [[ -n "$APP_PATH" ]]; then
        echo "  - REINSTALL ONLY FROM: $APP_PATH"
        echo "    Do NOT install any .app from ~/Library/Developer/Xcode/DerivedData."
        echo "    A DerivedData build product is LINKER-SIGNED, not codesigned: it has"
        echo "    Sealed Resources=none, so its keychain fails -34018 and every download"
        echo "    fails NSURLError -1. Those failures look like app or simulator bugs and"
        echo "    are neither. If you see -1 on every network request, check the signature"
        echo "    of the installed bundle BEFORE filing anything."
    fi
    echo "  - Hard stop at budget. No 'one more path.'"
    echo "  - Every finding requires log evidence from simdrive.logs."
    echo
    echo "When budget is exhausted, return the summary in the format from"
    echo "your system prompt and exit. Do not summarize verbosely."
} > "$PROMPT_FILE"

if (( DRY_RUN )); then
    echo "=== DRY RUN: prompt that would be sent ==="
    cat "$PROMPT_FILE"
    echo
    echo "=== Run dir: $RUN_DIR ==="
    exit 0
fi

# Invoke the subagent via headless Claude Code.
if ! command -v claude &> /dev/null; then
    echo "error: 'claude' CLI not found in PATH" >&2
    exit 2
fi

echo "info: chaos-qa session: $RUN_DIR" >&2
echo "info: seeds: ${SEEDS[*]}" >&2
echo "info: budget: ${MAX_PATHS} paths / ${MAX_MINUTES} minutes" >&2

# `claude -p` runs a single non-interactive prompt and exits.
# We pin to the chaos-qa agent (project-level definition).
SUMMARY_FILE="$RUN_DIR/summary.txt"
# The tools the chaos-qa subagent needs, declared HERE rather than assumed from
# the ambient session. `claude -p` is non-interactive: an ungranted tool cannot be
# approved mid-run, so the agent is denied, correctly refuses to invent findings,
# and the pass reports "returned cleanly / 0 findings" — indistinguishable from a
# clean chaos run. That happened on the 3.3.0 candidate: only
# mcp__simdrive__crashes was allowlisted, so every simdrive call was denied and
# ~30s of a 12-minute budget was spent discovering it.
# Keep this list in sync with .claude/agents/chaos-qa.md's `tools:` line. Declaring
# them here also means the orchestrator works on a machine whose (gitignored)
# settings.local.json has never heard of simdrive.
CHAOS_ALLOWED_TOOLS="Bash Read Write Edit TaskCreate TaskUpdate TaskList \
mcp__simdrive__session_start mcp__simdrive__session_end mcp__simdrive__session_status \
mcp__simdrive__observe mcp__simdrive__tap mcp__simdrive__swipe mcp__simdrive__type_text \
mcp__simdrive__press_key mcp__simdrive__record_start mcp__simdrive__record_stop \
mcp__simdrive__replay mcp__simdrive__logs mcp__simdrive__crashes \
mcp__simdrive__app_state mcp__simdrive__dismiss_first_launch_alerts \
mcp__simdrive__pre_grant_permissions mcp__simdrive__set_appearance"

# LIVENESS BASELINE. A chaos pass that never drives the simulator is worthless,
# and it is NOT distinguishable from a clean pass by its findings count — a real
# chaos run legitimately finds nothing sometimes. The discriminator is whether the
# agent ever opened a simdrive session. Snapshot the session store before the run
# and require a new one after. (2026-08-20: a whole fan reported "returned
# cleanly / 0 findings" on every area while being denied every simdrive call.)
CHAOS_SESSIONS_DIR="${CHAOS_SESSIONS_DIR:-$HOME/.simdrive/sessions}"
mkdir -p "$CHAOS_SESSIONS_DIR" 2>/dev/null || true
SESSIONS_BEFORE="$(ls -1 "$CHAOS_SESSIONS_DIR" 2>/dev/null | wc -l | tr -d ' ')"

CHAOS_CLAUDE_BIN="${CHAOS_CLAUDE_BIN:-claude}"
if "$CHAOS_CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
     --append-system-prompt "Use the chaos-qa subagent. Stay strictly within budget." \
     --allowedTools $CHAOS_ALLOWED_TOOLS \
     > "$SUMMARY_FILE" 2>"$RUN_DIR/stderr.log"; then
    echo "info: chaos-qa returned cleanly" >&2
else
    rc=$?
    echo "error: chaos-qa exited $rc; see $RUN_DIR/stderr.log" >&2
    # Don't fail the script — partial findings are still useful.
fi

# Synthesize summary.json from the CSV.
python3 - "$FINDINGS_CSV" "$RUN_DIR/summary.json" <<'PY'
import csv, json, sys
csv_path, json_path = sys.argv[1], sys.argv[2]
by_sev = {"blocker": 0, "major": 0, "minor": 0, "cosmetic": 0}
total = 0
with open(csv_path) as f:
    for row in csv.DictReader(f):
        total += 1
        sev = (row.get("Severity") or "").lower()
        if sev in by_sev:
            by_sev[sev] += 1
with open(json_path, "w") as f:
    json.dump({"total_findings": total, "by_severity": by_sev}, f, indent=2)
print(f"summary: {total} finding(s) in {csv_path}")
PY

# Did the agent actually drive the simulator?
SESSIONS_AFTER="$(ls -1 "$CHAOS_SESSIONS_DIR" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$SESSIONS_AFTER" -le "$SESSIONS_BEFORE" ]]; then
    {
      echo ""
      echo "!!! NO DRIVE — this chaos pass never opened a simdrive session."
      echo "!!! Sessions in $CHAOS_SESSIONS_DIR: $SESSIONS_BEFORE before, $SESSIONS_AFTER after."
      echo "!!! It explored 0 paths, so its 0 findings mean NOTHING was tested — that is"
      echo "!!! not the same as a clean pass, and must not be reported as one."
      echo "!!! Most common cause: the subagent was denied the mcp__simdrive__* tools."
      echo "!!! 'claude -p' is non-interactive and cannot approve a permission prompt, so"
      echo "!!! the tools must be granted at the invocation (--allowedTools)."
      echo "!!! Diagnose with: scripts/regression-preflight.sh --udid $UDID"
      echo "!!! Agent summary: $SUMMARY_FILE"
    } >&2
    echo "info: run complete (NO DRIVE): $RUN_DIR" >&2
    exit 4
fi

echo "info: run complete: $RUN_DIR"
exit 0
