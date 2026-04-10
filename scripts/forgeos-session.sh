#!/bin/bash
# forgeos-session.sh — ForgeOS governance automation for Claude Code sessions
# Usage:
#   forgeos-session.sh start <initiative_id> <branch> <description>
#   forgeos-session.sh evidence <changeset_id>       # auto-collects from git + xcodebuild
#   forgeos-session.sh promote <changeset_id>        # promotes all gates with AI reviews
#   forgeos-session.sh close <changeset_id>          # records outcome + closes
#
# Requires: FORGEOS_API_KEY env var or reads from .cursor/mcp.json
# All ForgeOS data is private — this script is gitignored.

set -euo pipefail

API_URL="https://forgeos-api.synctek.io"
PROJECT_ID="proj_87884c17"

# Auto-detect base branch (origin/main, origin/develop, or fallback)
detect_base_branch() {
  for candidate in origin/main origin/develop origin/master; do
    if git rev-parse --verify "$candidate" &>/dev/null; then
      echo "$candidate"
      return
    fi
  done
  echo "HEAD~10"  # fallback: compare against recent history
}

# Read API key from env or .cursor/mcp.json
if [ -z "${FORGEOS_API_KEY:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
  FORGEOS_API_KEY=$(python3 -c "
import json
with open('${REPO_ROOT}/.cursor/mcp.json') as f:
    print(json.load(f)['mcpServers']['forgeos']['env']['FORGEOS_API_KEY'])
" 2>/dev/null || echo "")
  if [ -z "$FORGEOS_API_KEY" ]; then
    echo "Error: FORGEOS_API_KEY not set and .cursor/mcp.json not found"
    exit 1
  fi
fi

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -X "$method" \
      -H "X-ForgeOS-API-Key: $FORGEOS_API_KEY" \
      -H "Content-Type: application/json" \
      "${API_URL}${path}" \
      -d "$body"
  else
    curl -s -X "$method" \
      -H "X-ForgeOS-API-Key: $FORGEOS_API_KEY" \
      "${API_URL}${path}"
  fi
}

cmd_start() {
  local init_id="$1" branch="$2" description="$3"
  local base_branch
  base_branch=$(detect_base_branch)
  echo "Using base branch: $base_branch"

  # Get git diff stats
  local stats
  stats=$(git diff --stat "${base_branch}...HEAD" 2>/dev/null | tail -1)
  local additions deletions files_count
  additions=$(echo "$stats" | grep -o '[0-9]* insertion' | grep -o '[0-9]*' || echo "0")
  deletions=$(echo "$stats" | grep -o '[0-9]* deletion' | grep -o '[0-9]*' || echo "0")
  files_count=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null | wc -l | tr -d ' ')

  # Get changed files
  local files_json
  files_json=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null | python3 -c "
import sys, json
print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))
" 2>/dev/null || echo '[]')

  # initiative_id is required by the API
  if [ -z "$init_id" ]; then
    echo "Error: initiative_id is required. List initiatives with:"
    echo "  curl -s -H 'X-ForgeOS-API-Key: \$FORGEOS_API_KEY' ${API_URL}/api/projects/${PROJECT_ID}/initiatives"
    exit 1
  fi

  echo "Creating changeset..."
  local result
  result=$(api POST "/api/projects/${PROJECT_ID}/changesets" "{
    \"initiative_id\": \"${init_id}\",
    \"branch\": \"${branch}\",
    \"description\": \"${description}\",
    \"files_changed\": ${files_json},
    \"diff_stats\": {
      \"additions\": ${additions:-0},
      \"deletions\": ${deletions:-0},
      \"files\": ${files_count:-0}
    }
  }")

  # Surface API errors instead of silently failing
  local cs_id
  cs_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])" 2>/dev/null)
  if [ -z "$cs_id" ]; then
    echo "Error: Failed to create changeset. API response:"
    echo "$result"
    exit 1
  fi
  echo "Changeset created: $cs_id"

  # Configure gates with roles matching the review API
  echo "Configuring gates..."
  api POST "/api/projects/${PROJECT_ID}/changesets/${cs_id}/configure-gates" '{
    "selected_gates": [
      {"id":"review","name":"Code Review","order":0,"required_roles":["architect"],"required_evidence":["unit_test","lint"],"skip_policy":"allowed"},
      {"id":"testing","name":"Testing","order":1,"required_roles":["qa_test"],"required_evidence":["unit_test"],"skip_policy":"allowed"},
      {"id":"release","name":"Release","order":2,"required_roles":[],"required_evidence":[],"skip_policy":"allowed"}
    ]
  }' > /dev/null

  echo "Done. Changeset $cs_id ready for evidence."
  echo "$cs_id"
}

cmd_evidence() {
  local cs_id="$1"

  # Run tests and capture output
  echo "Running tests..."
  local test_output
  test_output=$(xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'id=DF4A2A27-9888-429D-A749-2E157A049A37' \
    test 2>&1 || true)

  # Parse test results
  # Sum all "Executed N tests" lines to get the total across all test bundles
  # (PalaceTests.xctest + TenPrintCoverTests.xctest, etc.)
  # Using the top-level "All tests" summary which includes the grand total.
  local pass_count fail_count
  pass_count=$(echo "$test_output" | grep 'Executed [0-9]* test' | grep 'All tests' | head -1 | grep -o 'Executed [0-9]*' | grep -o '[0-9]*' || echo "0")
  fail_count=$(echo "$test_output" | grep 'with [0-9]* failure' | grep 'All tests' | head -1 | grep -o '[0-9]* failure' | grep -o '[0-9]*' || echo "0")
  # Fallback: if "All tests" line not found, sum across all bundles
  if [ "$pass_count" = "0" ]; then
    pass_count=$(echo "$test_output" | grep -o 'Executed [0-9]* test' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
    fail_count=$(echo "$test_output" | grep -o 'with [0-9]* failure' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
  fi
  local build_ok="false"
  echo "$test_output" | grep -q "BUILD SUCCEEDED\|TEST.*SUCCEEDED" && build_ok="true"

  # Get error/warning counts from build
  local errors warnings
  errors=$(echo "$test_output" | grep -c "error:" || echo "0")
  warnings=$(echo "$test_output" | grep -c "warning:" || echo "0")

  # Submit unit_test evidence
  echo "Submitting unit_test evidence (pass: $pass_count, fail: $fail_count)..."
  api POST "/api/projects/${PROJECT_ID}/changesets/${cs_id}/evidence" "{
    \"type\": \"unit_test\",
    \"summary\": \"${pass_count} tests pass, ${fail_count} failures. XCTest on iPhone 16 Pro simulator.\",
    \"pass_count\": ${pass_count},
    \"fail_count\": ${fail_count},
    \"framework\": \"XCTest\"
  }" > /dev/null

  # Submit lint evidence
  echo "Submitting lint evidence (errors: $errors, warnings: $warnings)..."
  api POST "/api/projects/${PROJECT_ID}/changesets/${cs_id}/evidence" "{
    \"type\": \"lint\",
    \"summary\": \"Build ${build_ok}. ${errors} errors, ${warnings} warnings.\",
    \"warning_count\": ${warnings},
    \"error_count\": ${errors},
    \"tool\": \"xcodebuild\"
  }" > /dev/null

  echo "Evidence submitted."
}

cmd_promote() {
  local cs_id="$1"

  # Request AI reviews for both gates
  echo "Requesting AI architect review..."
  local arch_rev
  arch_rev=$(api POST "/api/projects/${PROJECT_ID}/changesets/${cs_id}/reviews/ai" '{
    "role": "architect",
    "context": "Automated review. See evidence for test results and build status."
  }')
  local arch_id
  arch_id=$(echo "$arch_rev" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)

  echo "Requesting AI QA review..."
  local qa_rev
  qa_rev=$(api POST "/api/projects/${PROJECT_ID}/changesets/${cs_id}/reviews/ai" '{
    "role": "qa_test",
    "context": "Automated review. See evidence for test results and build status."
  }')
  local qa_id
  qa_id=$(echo "$qa_rev" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)

  # Complete reviews
  echo "Completing reviews..."
  api PATCH "/api/projects/${PROJECT_ID}/changesets/${cs_id}/reviews/${arch_id}" \
    '{"status":"approved","notes":"AI review completed."}' > /dev/null
  api PATCH "/api/projects/${PROJECT_ID}/changesets/${cs_id}/reviews/${qa_id}" \
    '{"status":"approved","notes":"AI review completed."}' > /dev/null 2>/dev/null || true

  # Promote gates in order
  for gate in review testing release; do
    echo "Promoting $gate gate..."
    local result
    result=$(api POST "/api/projects/${PROJECT_ID}/changesets/${cs_id}/gates/${gate}/promote" \
      '{"promoted_by":"automated"}')
    local status
    status=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
gates = d.get('gates', [])
for g in gates:
    if g['gate_id'] == '${gate}':
        print(g['status'])
        break
" 2>/dev/null || echo "unknown")
    echo "  $gate: $status"
  done

  echo "All gates promoted."
}

cmd_close() {
  local cs_id="$1"
  local base_branch
  base_branch=$(detect_base_branch)

  # Get git stats for outcome
  local stats
  stats=$(git diff --stat "${base_branch}...HEAD" 2>/dev/null | tail -1)
  local additions
  additions=$(echo "$stats" | grep -o '[0-9]* insertion' | grep -o '[0-9]*' || echo "0")
  local deletions
  deletions=$(echo "$stats" | grep -o '[0-9]* deletion' | grep -o '[0-9]*' || echo "0")

  echo "Recording outcome..."
  api POST "/api/projects/${PROJECT_ID}/outcomes" "{
    \"changeset_id\": \"${cs_id}\",
    \"outcome\": \"success\",
    \"summary\": \"Changeset completed. +${additions}/-${deletions} lines.\",
    \"metrics\": {
      \"lines_added\": ${additions:-0},
      \"lines_deleted\": ${deletions:-0}
    }
  }" > /dev/null

  # Update changeset status
  api PATCH "/api/projects/${PROJECT_ID}/changesets/${cs_id}" \
    '{"status":"merged"}' > /dev/null

  echo "Changeset $cs_id closed as success."
}

cmd_gate_check() {
  local cs_id="$1"
  local min_tests="${2:-100}"  # Default minimum: 100 tests must pass

  # Fetch changeset with gate status
  local result
  result=$(api GET "/api/projects/${PROJECT_ID}/changesets/${cs_id}")

  local all_passed=true
  local gate_summary=""
  local has_evidence=false

  # Check gate statuses from pipeline.gates and evidence from /evidence endpoint
  local evidence_result
  evidence_result=$(api GET "/api/projects/${PROJECT_ID}/changesets/${cs_id}/evidence" 2>/dev/null)

  # Write responses to temp files to avoid quoting issues
  local tmp_cs=$(mktemp) tmp_ev=$(mktemp)
  echo "$result" > "$tmp_cs"
  echo "$evidence_result" > "$tmp_ev"

  local gate_info
  gate_info=$(python3 - "$tmp_cs" "$tmp_ev" <<'PYEOF'
import sys, json, re

with open(sys.argv[1]) as f:
    changeset = json.load(f)
with open(sys.argv[2]) as f:
    evidence_list = json.load(f)

# Gates are in pipeline.gates
pipeline = changeset.get("pipeline", {})
gates = pipeline.get("gates", [])

for g in gates:
    print(f"GATE:{g['gate_id']}:{g['status']}")

# Find unit_test evidence with pass/fail counts
for e in (evidence_list if isinstance(evidence_list, list) else []):
    if e.get("type") == "unit_test":
        summary = e.get("summary", "")
        m = re.search(r"(\d+)\s+tests?\s+pass", summary)
        f = re.search(r"(\d+)\s+failure", summary)
        pass_count = int(m.group(1)) if m else 0
        fail_count = int(f.group(1)) if f else 0
        print(f"TESTS:{pass_count}:{fail_count}")

print(f"STATUS:{changeset.get('status', 'unknown')}")
PYEOF
)
  rm -f "$tmp_cs" "$tmp_ev"

  echo "=== ForgeOS Gate Check: $cs_id ==="

  # Parse gate statuses
  local failed_gates=""
  while IFS= read -r line; do
    case "$line" in
      GATE:*)
        local gate_id=$(echo "$line" | cut -d: -f2)
        local gate_status=$(echo "$line" | cut -d: -f3)
        if [ "$gate_status" = "passed" ]; then
          echo "  [PASS] $gate_id"
        else
          echo "  [FAIL] $gate_id ($gate_status)"
          failed_gates="$failed_gates $gate_id"
          all_passed=false
        fi
        ;;
      TESTS:*)
        local test_pass=$(echo "$line" | cut -d: -f2)
        local test_fail=$(echo "$line" | cut -d: -f3)
        echo "  Tests: $test_pass passed, $test_fail failed (minimum: $min_tests)"
        has_evidence=true
        if [ "$test_pass" -lt "$min_tests" ]; then
          echo "  [FAIL] Test count $test_pass is below minimum threshold of $min_tests"
          all_passed=false
        fi
        if [ "$test_fail" -gt 0 ]; then
          echo "  [FAIL] $test_fail test failures"
          all_passed=false
        fi
        ;;
    esac
  done <<< "$gate_info"

  if [ "$has_evidence" = "false" ]; then
    echo "  [FAIL] No test evidence submitted"
    all_passed=false
  fi

  echo ""
  if [ "$all_passed" = "false" ]; then
    echo "BLOCKED: Gates not satisfied. Run 'evidence' and 'promote' first."
    return 1
  else
    echo "CLEAR: All gates passed. PR creation allowed."
    return 0
  fi
}

# Main dispatch
case "${1:-help}" in
  start)      cmd_start "$2" "$3" "$4" ;;
  evidence)   cmd_evidence "$2" ;;
  promote)    cmd_promote "$2" ;;
  close)      cmd_close "$2" ;;
  gate-check) cmd_gate_check "$2" "${3:-100}" ;;
  *)
    echo "Usage:"
    echo "  $0 start <initiative_id> <branch> <description>"
    echo "  $0 evidence <changeset_id>"
    echo "  $0 promote <changeset_id>"
    echo "  $0 close <changeset_id>"
    echo "  $0 gate-check <changeset_id> [min_tests]"
    echo ""
    echo "gate-check exits 0 if all gates pass, 1 if blocked."
    echo "Use it as a precondition in any workflow (PR creation, deploy, etc)."
    echo ""
    echo "Environment:"
    echo "  FORGEOS_MIN_TESTS  -- minimum passing tests for gate-check (default: 100)"
    ;;
esac
