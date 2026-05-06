#!/bin/bash
# forgeos-orchestrate.sh — Multi-agent orchestration via ForgeOS
# Extends forgeos-session.sh with delegations, signals, execution dispatch, and sessions.
#
# Usage:
#   forgeos-orchestrate.sh session-start <description>
#   forgeos-orchestrate.sh session-end <session_id>
#   forgeos-orchestrate.sh task <session_id> <description>
#   forgeos-orchestrate.sh task-done <session_id> <task_id>
#   forgeos-orchestrate.sh delegate <initiative_id> <department> <action>
#   forgeos-orchestrate.sh delegate-receive <job_id> <agent_name>
#   forgeos-orchestrate.sh delegate-complete <job_id> [result_json]
#   forgeos-orchestrate.sh delegate-block <job_id> <reason>
#   forgeos-orchestrate.sh delegate-unblock <job_id>
#   forgeos-orchestrate.sh delegate-status [initiative_id]
#   forgeos-orchestrate.sh signal <type> <priority> <source_dept> <target_dept> <message> [initiative_id]
#   forgeos-orchestrate.sh signal-ack <signal_id> [note]
#   forgeos-orchestrate.sh signal-complete <signal_id> <resolution>
#   forgeos-orchestrate.sh dispatch <initiative_id> <action> [cost]
#   forgeos-orchestrate.sh exec-status
#   forgeos-orchestrate.sh exec-halt <reason>
#   forgeos-orchestrate.sh exec-resume
#   forgeos-orchestrate.sh stale-check [hours]
#   forgeos-orchestrate.sh report
#
# Requires: FORGEOS_API_KEY env var or reads from .cursor/mcp.json
# All ForgeOS data is private — this script is gitignored.

set -euo pipefail

API_URL="https://forgeos-api.synctek.io"
PROJECT_ID="proj_87884c17"

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

pp() { python3 -m json.tool 2>/dev/null || cat; }

# --- Sessions ---
cmd_session_start() {
  local desc="$1"
  local result
  result=$(api POST "/api/sessions" "{
    \"project_id\": \"${PROJECT_ID}\",
    \"developer_id\": \"claude-code\",
    \"description\": \"${desc}\"
  }")
  local sid
  sid=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
  echo "Session started: $sid"
  echo "$sid"
}

cmd_session_end() {
  local sid="$1"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  api PATCH "/api/sessions/${sid}" "{\"ended_at\": \"${now}\"}" | pp
  echo "Session $sid ended."
}

# --- Session Tasks ---
cmd_task() {
  local sid="$1" desc="$2" init_id="${3:-}"
  local body="{\"description\": \"${desc}\""
  if [ -n "$init_id" ]; then
    body="${body}, \"initiative_id\": \"${init_id}\""
  fi
  body="${body}}"
  local result
  result=$(api POST "/api/sessions/${sid}/tasks" "$body")
  local tid
  tid=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
  echo "Task created: $tid"
  echo "$tid"
}

cmd_task_done() {
  local sid="$1" tid="$2"
  api PATCH "/api/sessions/${sid}/tasks/${tid}" '{"status":"completed"}' | pp
}

# --- Delegations ---
cmd_delegate() {
  local init_id="$1" dept="$2" action="$3" gate="${4:-}"
  local body="{
    \"department\": \"${dept}\",
    \"action\": \"${action}\",
    \"initiative_id\": \"${init_id}\",
    \"created_by\": \"orchestrator\"
  }"
  if [ -n "$gate" ]; then
    body=$(echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['requires_gate'] = '${gate}'
print(json.dumps(d))
")
  fi
  local result
  result=$(api POST "/api/delegations" "$body")
  echo "$result" | pp
}

cmd_delegate_receive() {
  local job_id="$1" agent="$2"
  api PATCH "/api/delegations/${job_id}/receive" "{\"assigned_to\": \"${agent}\"}" | pp
}

cmd_delegate_complete() {
  local job_id="$1" result_json="${2:-null}"
  api PATCH "/api/delegations/${job_id}/complete" "{\"result\": ${result_json}}" | pp
}

cmd_delegate_block() {
  local job_id="$1" reason="$2"
  api PATCH "/api/delegations/${job_id}/block" "{\"reason\": \"${reason}\"}" | pp
}

cmd_delegate_unblock() {
  local job_id="$1"
  api PATCH "/api/delegations/${job_id}/unblock" '{}' | pp
}

cmd_delegate_status() {
  local init_id="${1:-}"
  local path="/api/delegations"
  if [ -n "$init_id" ]; then
    path="${path}?initiative_id=${init_id}"
  fi
  api GET "$path" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('No delegations found.')
else:
    for d in data:
        status = d.get('status','?')
        dept = d.get('department','?')
        action = d.get('action','?')
        assigned = d.get('assigned_to','unassigned')
        print(f'  [{status:10s}] {dept:15s} → {action} (assigned: {assigned})')
" 2>/dev/null
}

# --- Signals ---
cmd_signal() {
  local sig_type="$1" priority="$2" source="$3" target="$4" message="$5" init_id="${6:-}"
  local body="{
    \"signal_type\": \"${sig_type}\",
    \"priority\": \"${priority}\",
    \"source_department\": \"${source}\",
    \"target_department\": \"${target}\",
    \"message\": \"${message}\"
  }"
  if [ -n "$init_id" ]; then
    body=$(echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['initiative_id'] = '${init_id}'
print(json.dumps(d))
")
  fi
  local result
  result=$(api POST "/api/signals" "$body")
  echo "$result" | pp
}

cmd_signal_ack() {
  local sig_id="$1" note="${2:-}"
  local body="{}"
  if [ -n "$note" ]; then
    body="{\"note\": \"${note}\"}"
  fi
  api PATCH "/api/signals/${sig_id}/ack" "$body" | pp
}

cmd_signal_complete() {
  local sig_id="$1" resolution="$2"
  api PATCH "/api/signals/${sig_id}/complete" "{\"resolution\": \"${resolution}\"}" | pp
}

# --- Execution ---
cmd_dispatch() {
  local init_id="$1" action="$2" cost="${3:-0.5}"
  api POST "/api/execution/dispatch" "{
    \"initiative_id\": \"${init_id}\",
    \"action\": \"${action}\",
    \"cost\": ${cost}
  }" | pp
}

cmd_exec_status() {
  api GET "/api/execution/status" | pp
}

cmd_exec_halt() {
  local reason="$1"
  api POST "/api/execution/halt" "{\"reason\": \"${reason}\"}" | pp
}

cmd_exec_resume() {
  api POST "/api/execution/resume" '{}' | pp
}

# --- Reporting ---
cmd_stale_check() {
  local hours="${1:-24}"
  api GET "/api/delegations/stale?hours=${hours}" | pp
}

cmd_report() {
  echo "=== Delegation Report ==="
  api GET "/api/delegations/report" | pp
  echo ""
  echo "=== Execution Status ==="
  api GET "/api/execution/status" | pp
  echo ""
  echo "=== Active Sessions ==="
  api GET "/api/sessions/active?project_id=${PROJECT_ID}" | pp
  echo ""
  echo "=== Signal SLA Check ==="
  api GET "/api/signals/sla-check" | pp
}

# Main dispatch
case "${1:-help}" in
  session-start)      cmd_session_start "$2" ;;
  session-end)        cmd_session_end "$2" ;;
  task)               cmd_task "$2" "$3" "${4:-}" ;;
  task-done)          cmd_task_done "$2" "$3" ;;
  delegate)           cmd_delegate "$2" "$3" "$4" "${5:-}" ;;
  delegate-receive)   cmd_delegate_receive "$2" "$3" ;;
  delegate-complete)  cmd_delegate_complete "$2" "${3:-null}" ;;
  delegate-block)     cmd_delegate_block "$2" "$3" ;;
  delegate-unblock)   cmd_delegate_unblock "$2" ;;
  delegate-status)    cmd_delegate_status "${2:-}" ;;
  signal)             cmd_signal "$2" "$3" "$4" "$5" "$6" "${7:-}" ;;
  signal-ack)         cmd_signal_ack "$2" "${3:-}" ;;
  signal-complete)    cmd_signal_complete "$2" "$3" ;;
  dispatch)           cmd_dispatch "$2" "$3" "${4:-0.5}" ;;
  exec-status)        cmd_exec_status ;;
  exec-halt)          cmd_exec_halt "$2" ;;
  exec-resume)        cmd_exec_resume ;;
  stale-check)        cmd_stale_check "${2:-24}" ;;
  report)             cmd_report ;;
  *)
    echo "ForgeOS Multi-Agent Orchestration"
    echo ""
    echo "Sessions:"
    echo "  $0 session-start <description>"
    echo "  $0 session-end <session_id>"
    echo "  $0 task <session_id> <description> [initiative_id]"
    echo "  $0 task-done <session_id> <task_id>"
    echo ""
    echo "Delegations:"
    echo "  $0 delegate <initiative_id> <department> <action> [requires_gate]"
    echo "  $0 delegate-receive <job_id> <agent_name>"
    echo "  $0 delegate-complete <job_id> [result_json]"
    echo "  $0 delegate-block <job_id> <reason>"
    echo "  $0 delegate-unblock <job_id>"
    echo "  $0 delegate-status [initiative_id]"
    echo ""
    echo "Signals:"
    echo "  $0 signal <type> <priority> <source_dept> <target_dept> <message> [initiative_id]"
    echo "  $0 signal-ack <signal_id> [note]"
    echo "  $0 signal-complete <signal_id> <resolution>"
    echo "  Types: action_request|escalation|finding|acknowledgment|completion|verification|dependency|lesson"
    echo "  Priority: critical|high|medium|low"
    echo ""
    echo "Execution:"
    echo "  $0 dispatch <initiative_id> <action> [cost]"
    echo "  $0 exec-status"
    echo "  $0 exec-halt <reason>"
    echo "  $0 exec-resume"
    echo ""
    echo "Reporting:"
    echo "  $0 stale-check [hours]"
    echo "  $0 report"
    ;;
esac
