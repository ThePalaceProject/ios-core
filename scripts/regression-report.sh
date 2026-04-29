#!/bin/bash
# regression-report.sh — Orchestrator for regression testing workflow.
#
# Sets up the regression workspace, runs automated tools, and generates
# the final report and Jira tickets.
#
# Usage:
#   scripts/regression-report.sh setup   --ticket PP-XXXX --output-dir ~/Desktop/regression-PP-XXXX
#   scripts/regression-report.sh auto    --output-dir ~/Desktop/regression-PP-XXXX [--baseline-tag 2.2.5] [--candidate-branch modernize/whole-shot]
#   scripts/regression-report.sh report  --output-dir ~/Desktop/regression-PP-XXXX --baseline-version 2.2.5 --candidate-version 3.0.0
#   scripts/regression-report.sh tickets --output-dir ~/Desktop/regression-PP-XXXX --ticket PP-XXXX [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_CSV="$SCRIPT_DIR/templates/regression-findings.csv"

# Sim selection: prefer harness sim pool when present so parallel agents/QA
# testers don't collide. Fall back to a sane default. Override per-invocation
# with --sim-id (auto cmd) or by exporting SIM_ID before running.
default_sim_id() {
  local harness_default="$HOME/harness/projects/palace-ios.yml"
  if [[ -f "$harness_default" ]]; then
    awk -F: '/^[[:space:]]*default_sim_id:/ {gsub(/[" \047]/, "", $2); print $2; exit}' "$harness_default" 2>/dev/null
  fi
}
SIM_ID="${SIM_ID:-$(default_sim_id)}"
SIM_ID="${SIM_ID:-DF4A2A27-9888-429D-A749-2E157A049A37}"

usage() {
  cat << 'EOF'
Palace iOS Regression Testing Orchestrator

Commands:
  setup    Create regression workspace with directories and CSV template
  auto     Run automated testing tools (sync, mutation, push notifications)
  report   Generate interactive HTML report from findings CSV
  tickets  Generate Jira tickets from findings CSV
  checklist Print the manual testing checklist

Options:
  --ticket PP-XXXX           Parent Jira ticket
  --output-dir DIR           Regression workspace directory
  --baseline-tag TAG         Git tag for baseline build (for mutation testing)
  --candidate-branch BRANCH  Branch for candidate build (for mutation testing)
  --baseline-version VER     Version label for baseline (e.g., "2.2.5")
  --candidate-version VER    Version label for candidate (e.g., "3.0.0")
  --dry-run                  Preview without making changes

Options (auto command):
  --run-sync-tests           Invoke xcodebuild with curated sync test classes
  --skip-sync-tests          Explicitly skip sync tests
  --run-push                 Force-run push tests even without cached token
  --skip-push                Explicitly skip push tests
  --push-token TOKEN         FCM token for push tests (overrides cache/capture)
  --mutation-run             Execute mutants (default: dry-run enumeration only)
  --mutation-limit N         Cap number of files to mutate (default: all changed)
  --mutation-max-per-file N  Cap mutations per file (passthrough; default 8)
  --mutation-files LIST      Comma-separated list of source files to mutate
                              (overrides the changed-files derivation)
  --sim-id UDID              Override the simulator UDID
  --baseline-ref REF         Alias for --baseline-tag (any git ref accepted)
  --yes-long-mutation        Bypass the wallclock-estimate guard for >30 min runs

Workflow:
  1. scripts/regression-report.sh setup --ticket PP-XXXX --output-dir ~/Desktop/regression-PP-XXXX
  2. (Run automated tests)
     scripts/regression-report.sh auto --output-dir ~/Desktop/regression-PP-XXXX
  3. (Manual side-by-side testing — log findings to findings.csv)
  4. scripts/regression-report.sh report --output-dir ~/Desktop/regression-PP-XXXX
  5. scripts/regression-report.sh tickets --output-dir ~/Desktop/regression-PP-XXXX --ticket PP-XXXX --dry-run

Tip: --help / -h on any subcommand prints these options and exits cleanly.
EOF
}

# Derive an XCTestCase class name to test a given source file. Looks for a
# matching <basename>Tests.swift under PalaceTests/, falls back to scanning for
# any XCTestCase subclass declared in that file. Returns empty string on no
# match — caller must handle the fallback.
derive_test_class_for() {
  local source_file="$1"   # e.g. "Palace/Accounts/Library/AccountsManager.swift"
  local base
  base=$(basename "$source_file" .swift)
  # Try Foo.swift -> FooTests.swift first.
  local candidate
  candidate=$(find "$REPO_DIR/PalaceTests" -name "${base}Tests.swift" -not -path '*/Mocks/*' 2>/dev/null | head -1)
  if [[ -z "$candidate" ]]; then
    # Fallback: any test file mentioning the source class name.
    candidate=$(grep -rl "@testable import Palace" "$REPO_DIR/PalaceTests" 2>/dev/null \
      | xargs grep -l "\\b${base}\\b" 2>/dev/null \
      | head -1)
  fi
  if [[ -z "$candidate" ]]; then
    return 0  # no match — caller handles it
  fi
  # Pull the first XCTestCase subclass from the file. Matches both 'class X:'
  # and 'final class X:'.
  awk '/^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase/ {
    for (i=1; i<=NF; i++) if ($i == "class") { print $(i+1); exit }
  }' "$candidate" | tr -d ':'
}

# ============================================================
# SETUP — Create regression workspace
# ============================================================
cmd_setup() {
  local ticket=""
  local output_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help) usage; exit 0 ;;
      --ticket) ticket="$2"; shift 2 ;;
      --output-dir) output_dir="$2"; shift 2 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -z "$output_dir" ]]; then
    echo "Error: --output-dir is required"
    usage; exit 1
  fi

  if [[ -d "$output_dir" ]]; then
    echo "Workspace already exists at $output_dir (existing findings.csv preserved)"
  else
    echo "=== Creating regression workspace ==="
  fi

  # Always (re)create the canonical subdir layout. mkdir -p is idempotent;
  # this also recovers from manual archival of automated/* dirs between runs.
  mkdir -p "$output_dir"/{screenshots,video,report/assets/{screenshots,video,data},automated/{specterqa,sync,screenshots,mutation}}

  # CSV: only seed if missing (never overwrite a populated findings.csv).
  if [[ ! -f "$output_dir/findings.csv" ]]; then
    if [[ -f "$TEMPLATE_CSV" ]]; then
      cp "$TEMPLATE_CSV" "$output_dir/findings.csv"
      echo "  CSV template copied to $output_dir/findings.csv"
    else
      echo "  Warning: template not found at $TEMPLATE_CSV"
      echo "ID,Title,Area,Test ID,Classification,Severity,Verified,Baseline Behavior,Candidate Behavior,Steps,Screenshot Baseline,Screenshot Candidate,Notes,PR,Jira Ticket" > "$output_dir/findings.csv"
      echo "  Created blank CSV at $output_dir/findings.csv"
    fi
  fi

  # Test matrix: always sync (the matrix can evolve between runs).
  if [[ -f "$REPO_DIR/docs/Testing/REGRESSION_TEST_MATRIX.md" ]]; then
    cp "$REPO_DIR/docs/Testing/REGRESSION_TEST_MATRIX.md" "$output_dir/TEST_MATRIX.md"
  fi

  # ENVIRONMENT.md: only seed if missing. Tester edits MUST be preserved.
  if [[ -f "$output_dir/ENVIRONMENT.md" ]]; then
    echo "  ENVIRONMENT.md preserved (tester-edited)"
  else
    cat > "$output_dir/ENVIRONMENT.md" << ENVEOF
# Regression Test Environment

**Ticket:** ${ticket:-TBD}
**Date:** $(date +%Y-%m-%d)
**Tester:** $(git config user.name)

## Builds

| Build | Version | Source | Device |
|-------|---------|--------|--------|
| Baseline | TBD | TBD | TBD |
| Candidate | TBD | TBD | TBD |

## Simulators

| Simulator | ID | OS |
|-----------|-----|-----|
| iPhone 16 Pro | $SIM_ID | iOS 18.4 |

## Test Libraries

| Library | Auth Type | Credentials |
|---------|-----------|-------------|
| A1QA Test Library | Basic | See ~/.specterqa/credentials/a1qa-test.env |
| Lyrasis Reads | None | N/A |
| Palace Bookshelf | Anonymous | N/A |

## Setup Commands

\`\`\`bash
# Boot simulator and configure
xcrun simctl boot $SIM_ID 2>/dev/null || true
xcrun simctl spawn $SIM_ID defaults write org.thepalaceproject.palace showDeveloperSettings -bool true
xcrun simctl spawn $SIM_ID defaults write org.thepalaceproject.palace NYPLUseBetaLibrariesKey -bool true
\`\`\`
ENVEOF
    echo "  ENVIRONMENT.md seeded from template (fill in build/sim details)"
  fi

  echo ""
  echo "=== Workspace ready at $output_dir ==="
  echo ""
  echo "Next steps:"
  echo "  1. Fill in ENVIRONMENT.md with build details"
  echo "  2. Run automated sweep: scripts/regression-report.sh auto --output-dir $output_dir"
  echo "  3. Do manual side-by-side testing (see TEST_MATRIX.md)"
  echo "  4. Log findings to findings.csv (Verified=false until confirmed)"
  echo "  5. Generate report: scripts/regression-report.sh report --output-dir $output_dir"
}

# ============================================================
# AUTO — Run automated testing tools
# ============================================================
cmd_auto() {
  local output_dir=""
  local baseline_tag=""
  local candidate_branch=""
  local push_token=""
  local push_mode="auto"          # auto | run | skip
  local sync_mode="auto"          # auto | run | skip
  local mutation_run="false"      # dry-run by default; --mutation-run to execute
  local mutation_limit=""         # empty = no cap (all changed files)
  local mutation_max_per_file="8" # sensible cap; tester can override
  local mutation_files=""         # comma-separated; overrides --baseline-tag derivation
  local mutation_test_class=""    # override per-file test-class derivation
  local yes_long_mutation="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help) usage; exit 0 ;;
      --output-dir) output_dir="$2"; shift 2 ;;
      --baseline-tag|--baseline-ref) baseline_tag="$2"; shift 2 ;;
      --candidate-branch) candidate_branch="$2"; shift 2 ;;
      --sim-id) SIM_ID="$2"; shift 2 ;;
      --push-token) push_token="$2"; shift 2 ;;
      --run-push) push_mode="run"; shift ;;
      --skip-push) push_mode="skip"; shift ;;
      --run-sync-tests) sync_mode="run"; shift ;;
      --skip-sync-tests) sync_mode="skip"; shift ;;
      --mutation-run) mutation_run="true"; shift ;;
      --mutation-limit) mutation_limit="$2"; shift 2 ;;
      --mutation-max-per-file) mutation_max_per_file="$2"; shift 2 ;;
      --mutation-files) mutation_files="$2"; shift 2 ;;
      --mutation-test-class) mutation_test_class="$2"; shift 2 ;;
      --yes-long-mutation) yes_long_mutation="true"; shift ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -z "$output_dir" ]]; then
    echo "Error: --output-dir is required"; usage; exit 1
  fi

  # Defensive mkdir — auto can run after a manual cleanup of automated/*.
  mkdir -p "$output_dir/automated"/{specterqa,sync,screenshots,mutation}

  local exit_code=0

  echo "=== Running automated regression tools ==="
  echo "  sim: $SIM_ID"
  echo ""

  # --- Annotation sync tests (curated xcodebuild run) ---
  # Curated list of sync-related XCTestCase classes. These are the test classes
  # that exercise annotation/position/bookmark/notification sync paths and
  # should pass cleanly on both baseline and candidate.
  local sync_test_classes=(
    "PalaceTests/PositionSyncTests"
    "PalaceTests/PositionPersistenceTests"
    "PalaceTests/SyncConflictResolutionTests"
    "PalaceTests/TPPLastReadPositionSynchronizerTests"
    "PalaceTests/TPPLastReadPositionSynchronizerIntegrationTests"
    "PalaceTests/ReadingPositionTests"
    "PalaceTests/PositionSyncServiceTests"
    "PalaceTests/TPPAnnotationsTests"
    "PalaceTests/TPPAnnotationsHermeticTests"
    "PalaceTests/BookRegistrySyncTests"
    "PalaceTests/CrossDeviceBookmarkSyncTests"
    "PalaceTests/AudiobookDataManagerNetworkSyncTests"
    "PalaceTests/AudiobookDataManagerErrorHandlingTests"
    "PalaceTests/NotificationSyncThrottleTests"
    "PalaceTests/HoldNotificationClassificationTests"
  )

  if [[ "$sync_mode" == "skip" ]]; then
    echo "--- Annotation sync tests: SKIPPED (--skip-sync-tests) ---"
  elif [[ "$sync_mode" == "auto" ]]; then
    echo "--- Annotation sync tests: SKIPPED (pass --run-sync-tests to invoke xcodebuild on ${#sync_test_classes[@]} classes) ---"
    printf '%s\n' "${sync_test_classes[@]}" > "$output_dir/automated/sync/planned-classes.txt"
  else
    echo "--- Annotation sync tests (xcodebuild on ${#sync_test_classes[@]} classes) ---"
    local only_args=()
    for c in "${sync_test_classes[@]}"; do only_args+=("-only-testing:$c"); done
    (
      cd "$REPO_DIR" && \
      xcodebuild -project Palace.xcodeproj -scheme Palace \
        -destination "platform=iOS Simulator,id=$SIM_ID" \
        "${only_args[@]}" test
    ) > "$output_dir/automated/sync/results.txt" 2>&1 && \
      echo "  PASS — results at automated/sync/results.txt" || \
      { echo "  FAIL — check automated/sync/results.txt"; exit_code=1; }
  fi

  # --- Push notification tests ---
  local push_cache="$HOME/.palace/fcm-token-cache.json"
  local push_sa="$HOME/.palace/firebase-service-account.json"
  local push_out="$output_dir/automated/sync/push-results.txt"

  if [[ ! -f "$SCRIPT_DIR/test-push-notifications.py" ]]; then
    echo "--- Push notification tests: SKIPPED (scripts/test-push-notifications.py not found) ---"
  elif [[ "$push_mode" == "skip" ]]; then
    echo "--- Push notification tests: SKIPPED (--skip-push) ---"
  elif [[ ! -f "$push_sa" ]]; then
    echo "--- Push notification tests: SKIPPED (no Firebase service account at $push_sa) ---"
    echo "To enable: see scripts/test-push-notifications.py --help" > "$push_out"
  elif [[ "$push_mode" == "auto" && -z "$push_token" && ! -f "$push_cache" ]]; then
    echo "--- Push notification tests: SKIPPED (no cached FCM token; pass --push-token or plug in device + run 'scripts/test-push-notifications.py capture-token') ---"
    {
      echo "SKIPPED — no FCM token available."
      echo "To enable: capture a token from a physical device first:"
      echo "  python3 scripts/test-push-notifications.py capture-token"
      echo "Then re-run with --run-push (or pass --push-token TOKEN)."
    } > "$push_out"
  else
    echo "--- Push notification tests ---"
    local push_args=()
    if [[ -n "$push_token" ]]; then push_args+=("--token" "$push_token"); fi
    push_args+=("all")
    python3 "$SCRIPT_DIR/test-push-notifications.py" "${push_args[@]}" > "$push_out" 2>&1 && \
      echo "  PASS — results at automated/sync/push-results.txt" || \
      { echo "  FAIL — check automated/sync/push-results.txt"; exit_code=1; }
  fi

  # --- Mutation testing on changed files ---
  if [[ ! -f "$SCRIPT_DIR/palace_mutate.py" ]]; then
    echo "--- Mutation testing: SKIPPED (palace_mutate.py not found at $SCRIPT_DIR) ---"
  elif [[ -z "$mutation_files" && ( -z "$baseline_tag" || -z "$candidate_branch" ) ]]; then
    echo "--- Mutation testing: SKIPPED (need --baseline-tag (or --baseline-ref) + --candidate-branch, OR --mutation-files LIST) ---"
  else
    local mode_label; mode_label=$([[ "$mutation_run" == "true" ]] && echo "REAL execution" || echo "dry-run")
    if [[ -n "$mutation_files" ]]; then
      echo "--- Mutation testing [$mode_label] (--mutation-files override: $(echo "$mutation_files" | tr ',' '\n' | wc -l | tr -d ' ') files) ---"
    else
      echo "--- Mutation testing [$mode_label] (changed files between $baseline_tag and $candidate_branch) ---"
    fi

    local changed_files
    if [[ -n "$mutation_files" ]]; then
      changed_files=$(echo "$mutation_files" | tr ',' '\n')
    else
      changed_files=$(git -C "$REPO_DIR" diff --name-only "$baseline_tag...$candidate_branch" -- '*.swift' \
        | grep -Ev '(^|/)(PalaceTests|PalaceUITests|Tests)/' || true)
    fi

    if [[ -n "$mutation_limit" ]]; then
      changed_files=$(echo "$changed_files" | head -n "$mutation_limit")
    fi
    if [[ -z "$changed_files" ]]; then
      echo "  No source files to mutate."
    else
      echo "$changed_files" > "$output_dir/automated/mutation/changed-files.txt"
      : > "$output_dir/automated/mutation/results.txt"
      local total
      total=$(echo "$changed_files" | wc -l | tr -d ' ')
      local reports_dir="$output_dir/automated/mutation/reports"
      mkdir -p "$reports_dir"

      # Wallclock guard: only fires for real execution. ~90s/mutation × max
      # ~20/file (palace_mutate default) gives a rough upper bound. Actual cost
      # depends on test-class compile time, but the order of magnitude is right.
      local guard_skip="false"
      if [[ "$mutation_run" == "true" && "$yes_long_mutation" != "true" ]]; then
        local per_file_cap="${mutation_max_per_file:-20}"
        local est_min=$(( total * per_file_cap * 90 / 60 ))
        if [[ "$est_min" -gt 30 ]]; then
          echo ""
          echo "  ⚠  Estimated wallclock for real mutation: ${est_min} min."
          echo "      total_files=$total × per_file=$per_file_cap × 90s/mutation"
          echo "      Pass --yes-long-mutation to proceed, or tighten --mutation-limit /"
          echo "      --mutation-max-per-file. Skipping mutation execution."
          echo "Mutation execution skipped: estimated ${est_min} min exceeds 30 min guard." \
            >> "$output_dir/automated/mutation/results.txt"
          guard_skip="true"
        fi
      fi

      local count=0
      local mutated=0
      local empty=0
      local skipped=0
      local extra_args=()
      [[ "$mutation_run" != "true" ]] && extra_args+=(--dry-run)
      [[ -n "$mutation_max_per_file" ]] && extra_args+=(--max-mutations "$mutation_max_per_file")

      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        count=$((count + 1))
        if [[ ! -f "$REPO_DIR/$file" ]]; then
          echo "  [$count/$total] $file  (SKIP — file does not exist in candidate)"
          echo "SKIP $file (deleted or renamed)" >> "$output_dir/automated/mutation/results.txt"
          skipped=$((skipped + 1))
          continue
        fi

        # Derive the right XCTestCase class name. Override > derivation > fallback.
        local cls="$mutation_test_class"
        if [[ -z "$cls" ]]; then
          cls=$(derive_test_class_for "$file")
        fi
        if [[ -z "$cls" ]]; then
          echo "  [$count/$total] $file  (SKIP — no matching test class found)"
          echo "SKIP $file (no test class — pass --mutation-test-class to force)" \
            >> "$output_dir/automated/mutation/results.txt"
          skipped=$((skipped + 1))
          continue
        fi

        echo "  [$count/$total] $file  (tests: PalaceTests/$cls)"

        local slug
        slug=$(echo "$file" | tr '/' '_' | sed 's/\.swift$//')
        (
          cd "$REPO_DIR" && \
          python3 "$SCRIPT_DIR/palace_mutate.py" \
            --file "$file" \
            --tests "PalaceTests/$cls" \
            --report "$reports_dir/$slug.json" \
            "${extra_args[@]}"
        ) >> "$output_dir/automated/mutation/results.txt" 2>&1 || true

        # Track files-with-mutations vs no-mutation files for honest reporting.
        if grep -q "No mutation points found in $file" "$output_dir/automated/mutation/results.txt" 2>/dev/null; then
          empty=$((empty + 1))
        else
          mutated=$((mutated + 1))
        fi
      done <<< "$([[ "$guard_skip" == "true" ]] && echo "" || echo "$changed_files")"

      # --- Aggregate summary ---
      local summary="$output_dir/automated/mutation/summary.txt"
      {
        echo "Mutation summary ($mode_label)"
        echo "  files scanned: $count"
        echo "  files with mutations: $mutated"
        echo "  files with no mutations (skipped — pure-shape source): $empty"
        echo "  files skipped (missing / no test class): $skipped"
        if [[ "$mutation_run" == "true" ]]; then
          # Real execution: parse per-file JSON reports for kill rates.
          python3 "$SCRIPT_DIR/summarize-mutation-reports.py" "$reports_dir" 2>/dev/null \
            | sed 's/^/  /' || echo "  (summarize-mutation-reports.py not found)"
        else
          # Dry-run: parse results.txt for mutation-point counts.
          local total_pts
          total_pts=$(grep -oE "total mutation points discovered: [0-9]+" \
            "$output_dir/automated/mutation/results.txt" | awk '{sum+=$NF} END{print sum+0}')
          echo "  total mutation points discovered: $total_pts"
          echo ""
          echo "  Top 10 by mutation surface:"
          awk '/^palace-mutate:/{file=$2} /total mutation points discovered:/{print $NF, file}' \
            "$output_dir/automated/mutation/results.txt" 2>/dev/null \
            | sort -nr | head -10 | awk '{printf "    %4d  %s\n", $1, $2}'
          echo ""
          echo "  (re-run with --mutation-run to get real kill/survive data)"
        fi
      } > "$summary"
      echo "  Results: automated/mutation/results.txt"
      echo "  Per-file JSON reports: automated/mutation/reports/"
      echo "  Aggregate summary: automated/mutation/summary.txt"
      sed 's/^/    /' "$summary"
    fi
  fi

  # --- BrowserStack screenshot walker ---
  if [[ -f "$SCRIPT_DIR/browserstack-screenshot-walker.py" ]]; then
    echo "--- BrowserStack screenshot walker ---"
    echo "  Run manually: python3 $SCRIPT_DIR/browserstack-screenshot-walker.py"
    echo "  Save output to: $output_dir/automated/screenshots/"
  else
    echo "--- BrowserStack screenshots: SKIPPED (script not found) ---"
  fi

  echo ""
  echo "=== Automated sweep complete (exit=$exit_code) ==="
  echo ""
  echo "Next: manual side-by-side testing. Run 'scripts/regression-report.sh checklist' for the test matrix."
  return $exit_code
}

# ============================================================
# REPORT — Generate HTML report
# ============================================================
cmd_report() {
  local output_dir=""
  local baseline_version=""
  local candidate_version=""
  local title=""
  local video=""
  local strict=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help) usage; exit 0 ;;
      --output-dir) output_dir="$2"; shift 2 ;;
      --baseline-version) baseline_version="$2"; shift 2 ;;
      --candidate-version) candidate_version="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --video) video="$2"; shift 2 ;;
      --strict) strict="--strict"; shift ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -z "$output_dir" ]]; then
    echo "Error: --output-dir is required"; usage; exit 1
  fi

  local csv="$output_dir/findings.csv"
  local screenshots="$output_dir/screenshots"
  local report_output="$output_dir/report/index.html"

  if [[ ! -f "$csv" ]]; then
    echo "Error: findings.csv not found at $csv"
    exit 1
  fi

  # Backup CSV before any processing
  cp "$csv" "${csv}.$(date +%Y%m%d_%H%M%S).bak"

  local video_arg=""
  if [[ -n "$video" ]]; then
    video_arg="--video $video"
  fi

  echo "=== Generating regression report ==="

  # Two-stage: validate first (fast, exits non-zero on bad CSV), then generate.
  # generate-regression-report.py treats --validate as exit-after-validation, so
  # passing it to the same call as --output silently skips file write.
  python3 "$SCRIPT_DIR/generate-regression-report.py" \
    --csv "$csv" \
    --screenshots "$screenshots" \
    --validate \
    $strict

  python3 "$SCRIPT_DIR/generate-regression-report.py" \
    --csv "$csv" \
    --screenshots "$screenshots" \
    --output "$report_output" \
    --baseline-version "${baseline_version:-baseline}" \
    --candidate-version "${candidate_version:-candidate}" \
    ${title:+--title "$title"} \
    $video_arg

  if [[ ! -f "$report_output" ]]; then
    echo "Error: report generation reported success but $report_output is missing." >&2
    echo "  Check the python output above for clues; this should not happen." >&2
    exit 2
  fi

  echo ""
  echo "Report generated at: $report_output ($(wc -c < "$report_output" | tr -d ' ') bytes)"
  echo "Open: open $report_output"
}

# ============================================================
# TICKETS — Generate Jira tickets
# ============================================================
cmd_tickets() {
  local output_dir=""
  local ticket=""
  local dry_run=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help) usage; exit 0 ;;
      --output-dir) output_dir="$2"; shift 2 ;;
      --ticket) ticket="$2"; shift 2 ;;
      --dry-run) dry_run="--dry-run"; shift ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -z "$output_dir" || -z "$ticket" ]]; then
    echo "Error: --output-dir and --ticket are required"; usage; exit 1
  fi

  local csv="$output_dir/findings.csv"

  if [[ ! -f "$csv" ]]; then
    echo "Error: findings.csv not found at $csv"
    exit 1
  fi

  # Load Jira credentials
  if [[ -z "${JIRA_EMAIL:-}" || -z "${JIRA_API_TOKEN:-}" ]]; then
    if [[ -f "$REPO_DIR/.jira-config" ]]; then
      source "$REPO_DIR/.jira-config"
      export JIRA_EMAIL JIRA_API_TOKEN
    else
      echo "Error: Set JIRA_EMAIL and JIRA_API_TOKEN environment variables, or create .jira-config"
      exit 1
    fi
  fi

  echo "=== Generating Jira tickets ==="
  python3 "$SCRIPT_DIR/generate-jira-tickets.py" \
    --csv "$csv" \
    --parent "$ticket" \
    --component iOS \
    --update-csv \
    $dry_run
}

# ============================================================
# CHECKLIST — Print manual testing checklist
# ============================================================
cmd_checklist() {
  if [[ -f "$REPO_DIR/docs/Testing/REGRESSION_TEST_MATRIX.md" ]]; then
    cat "$REPO_DIR/docs/Testing/REGRESSION_TEST_MATRIX.md"
  else
    echo "Test matrix not found at docs/Testing/REGRESSION_TEST_MATRIX.md"
    exit 1
  fi
}

# ============================================================
# Main dispatcher
# ============================================================
if [[ $# -lt 1 ]]; then
  usage; exit 0
fi

command="$1"
shift

case "$command" in
  -h|--help|help) usage; exit 0 ;;
  setup) cmd_setup "$@" ;;
  auto) cmd_auto "$@" ;;
  report) cmd_report "$@" ;;
  tickets) cmd_tickets "$@" ;;
  checklist) cmd_checklist "$@" ;;
  *) echo "Unknown command: $command" >&2; usage >&2; exit 1 ;;
esac
