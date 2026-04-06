#!/bin/bash
#
# Jira Integration Script for Palace iOS
# 
# Full JIRA lifecycle management from the command line.
# Designed so that AI agents (Cursor, Codex, etc.) can manage tickets
# without needing ad-hoc curl calls or session-specific knowledge.
#
# Capabilities:
# - Search and view existing tickets
# - Create new tickets (bug, task, story)
# - Assign tickets, set story points
# - Move tickets to sprints, transition status
# - Add comments, link commits, add structured fix details
#
# Common workflows:
#   # Find an existing ticket and update it
#   ./jira-integration.sh search "download hang audiobook"
#   ./jira-integration.sh view PP-3692
#   ./jira-integration.sh assign PP-3692 me
#   ./jira-integration.sh set-points PP-3692 5
#   ./jira-integration.sh move-to-sprint PP-3692 current
#   ./jira-integration.sh transition PP-3692 "Code Review"
#   ./jira-integration.sh comment PP-3692 "Fix submitted in PR #760"
#
#   # Create a new ticket when one doesn't exist
#   ./jira-integration.sh create bug "Summary here" "Description here"
#
#   # View sprint info
#   ./jira-integration.sh get-sprints active
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.jira-config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}⚠️  Jira config not found at $CONFIG_FILE${NC}"
    echo -e "${YELLOW}   Copy .jira-config.template to .jira-config and fill in your credentials${NC}"
    return 1
  fi
  source "$CONFIG_FILE"
  
  if [[ -z "$JIRA_URL" || -z "$JIRA_EMAIL" || -z "$JIRA_API_TOKEN" ]]; then
    echo -e "${RED}❌ Jira configuration incomplete. Check .jira-config${NC}"
    return 1
  fi
  return 0
}

# Extract ticket number from text (e.g., "PP-3605" from commit message)
extract_ticket() {
  local text="$1"
  local project_key="${JIRA_PROJECT_KEY:-PP}"
  echo "$text" | grep -oE "${project_key}-[0-9]+" | head -1
}

# Check if ticket exists in Jira
ticket_exists() {
  local ticket="$1"
  
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$JIRA_URL/rest/api/3/issue/$ticket")
  
  [[ "$response" == "200" ]]
}

# Get available transitions for a ticket
get_transitions() {
  local ticket="$1"
  
  curl -s \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$JIRA_URL/rest/api/3/issue/$ticket/transitions"
}

# Find transition ID by name (case-insensitive partial match)
find_transition_id() {
  local ticket="$1"
  local target_name="$2"
  
  local transitions
  transitions=$(get_transitions "$ticket")
  
  # Find transition ID matching the target name (case-insensitive)
  echo "$transitions" | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '${target_name}'.lower()
for t in data.get('transitions', []):
    name = t.get('name', '').lower()
    if target in name or name in target:
        print(t['id'])
        sys.exit(0)
# Try common variations
variations = {
    'code review': ['in review', 'review', 'code review', 'peer review'],
    'done': ['done', 'closed', 'resolved', 'complete'],
    'in progress': ['in progress', 'in development', 'developing', 'started']
}
target_variations = variations.get(target, [target])
for t in data.get('transitions', []):
    name = t.get('name', '').lower()
    for v in target_variations:
        if v in name:
            print(t['id'])
            sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# Transition a ticket to a new status
transition_ticket() {
  local ticket="$1"
  local status="$2"
  
  if ! load_config; then
    return 1
  fi
  
  if [[ -z "$ticket" || -z "$status" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh transition <ticket> <status>${NC}"
    echo -e "   Status can be: 'Code Review', 'Done', 'In Progress', etc."
    return 1
  fi
  
  echo -e "${BLUE}🔄 Transitioning $ticket to '$status'...${NC}"
  
  # Find the transition ID
  local transition_id
  transition_id=$(find_transition_id "$ticket" "$status")
  
  if [[ -z "$transition_id" ]]; then
    echo -e "${YELLOW}⚠️  Could not find transition to '$status' for $ticket${NC}"
    echo -e "${YELLOW}   Available transitions:${NC}"
    get_transitions "$ticket" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data.get('transitions', []):
    print(f\"   - {t['name']} (id: {t['id']})\")
" 2>/dev/null || echo "   (unable to list transitions)"
    return 1
  fi
  
  # Execute the transition
  local response
  response=$(curl -s -w "\n%{http_code}" \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"transition\": {\"id\": \"$transition_id\"}}" \
    "$JIRA_URL/rest/api/3/issue/$ticket/transitions")
  
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')
  
  if [[ "$http_code" == "204" ]]; then
    echo -e "${GREEN}✅ $ticket transitioned to '$status'${NC}"
    return 0
  else
    echo -e "${RED}❌ Failed to transition $ticket (HTTP $http_code)${NC}"
    if [[ -n "$body" ]]; then
      echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('errorMessages', d))" 2>/dev/null || echo "$body"
    fi
    return 1
  fi
}

# Add a comment to a Jira ticket
add_comment() {
  local ticket="$1"
  local comment="$2"
  
  if ! load_config; then
    return 1
  fi
  
  if [[ -z "$ticket" || -z "$comment" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh comment <ticket> <comment>${NC}"
    return 1
  fi
  
  echo -e "${BLUE}📝 Adding comment to $ticket...${NC}"
  
  # Use jq for proper JSON escaping
  local json_payload
  json_payload=$(jq -n --arg text "$comment" '{
    body: {
      type: "doc",
      version: 1,
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: $text
            }
          ]
        }
      ]
    }
  }')
  
  local response
  response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "$JIRA_URL/rest/api/3/issue/$ticket/comment")
  
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')
  
  if [[ "$http_code" == "201" ]]; then
    echo -e "${GREEN}✅ Comment added to $ticket${NC}"
    return 0
  else
    echo -e "${RED}❌ Failed to add comment (HTTP $http_code)${NC}"
    echo "$body"
    return 1
  fi
}

# Convert text with numbered items to Jira ADF list format
# Input: "1. First item 2. Second item" or "1. First\n2. Second"
# Output: One item per line with number prefixes stripped
# Note: Uses python3 for reliable cross-platform regex (BSD sed on macOS
#       does not support \+, \s, or \n in replacements)
build_list_items() {
  local text="$1"
  
  python3 -c "
import re, sys

text = sys.argv[1]

# Normalize literal backslash-n to real newlines
text = text.replace(r'\n', '\n')

# Split on numbered prefixes: '1. ', '2. ', etc.
# Handles both inline ('1. foo 2. bar') and newline-separated formats
items = re.split(r'(?:^|\s)(?=\d+\.\s)', text.strip())

for item in items:
    # Strip the leading number prefix and whitespace
    item = re.sub(r'^\d+\.\s*', '', item).strip()
    if item:
        print(item)
" "$text"
}

# Find existing "Ready for QA" or "Fix Details" comment ID for a ticket
find_fix_comment_id() {
  local ticket="$1"
  
  local response
  response=$(curl -s \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$JIRA_URL/rest/api/3/issue/$ticket/comment")
  
  # Find comment containing our fix-details heading (updated text or legacy)
  echo "$response" | jq -r '
    [.comments[]? | select(
      (.body.content[]?.content[]?.text? // empty) | test("Ready for QA|Fix Details")
    ) | .id] | first // empty
  ' 2>/dev/null
}

# Add a structured fix comment for QA: what changed + how to verify
add_fix_comment() {
  local ticket="$1"
  local root_cause="$2"
  local testing_steps="$3"
  local commit_sha="${4:-$(git rev-parse HEAD 2>/dev/null || echo '')}"
  
  if ! load_config; then
    return 1
  fi
  
  if [[ -z "$ticket" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh add-fix-comment <ticket> <what_changed> <how_to_verify_qa> [commit_sha]${NC}"
    return 1
  fi
  
  echo -e "${BLUE}📝 Adding fix details to $ticket...${NC}"
  
  # Check for existing fix comment to update
  local existing_comment_id
  existing_comment_id=$(find_fix_comment_id "$ticket")
  
  if [[ -n "$existing_comment_id" ]]; then
    echo -e "${YELLOW}   Found existing fix comment, updating...${NC}"
  fi
  
  # Get commit info if available
  local commit_info=""
  if [[ -n "$commit_sha" ]]; then
    local commit_msg
    commit_msg=$(git log -1 --format="%s" "$commit_sha" 2>/dev/null || echo "")
    local commit_author
    commit_author=$(git log -1 --format="%an" "$commit_sha" 2>/dev/null || echo "")
    local commit_date
    commit_date=$(git log -1 --format="%ai" "$commit_sha" 2>/dev/null || echo "")
    
    if [[ -n "$commit_msg" ]]; then
      commit_info="Commit: ${commit_sha:0:12}
Author: $commit_author
Date: $commit_date
Message: $commit_msg"
    fi
  fi
  
  # Build list items from testing steps
  local list_items_json="[]"
  if [[ "$testing_steps" =~ [0-9]+\. ]]; then
    # Has numbered items - build as ordered list
    list_items_json=$(build_list_items "$testing_steps" | jq -R -s 'split("\n") | map(select(length > 0)) | map({
      type: "listItem",
      content: [{
        type: "paragraph",
        content: [{ type: "text", text: . }]
      }]
    })')
  fi
  
  # Use jq for proper JSON construction with escaping
  local json_payload
  # Omit Build/commit section when commit_info is empty (empty codeBlock can break JIRA API)
  if [[ "$list_items_json" != "[]" ]]; then
    # Use ordered list for testing steps
    json_payload=$(jq -n \
      --arg root_cause "$root_cause" \
      --argjson list_items "$list_items_json" \
      --arg commit_info "$commit_info" \
      '(
        [
          { type: "heading", attrs: { level: 3 }, content: [{ type: "text", text: "✅ Ready for QA" }] },
          { type: "heading", attrs: { level: 4 }, content: [{ type: "text", text: "What changed" }] },
          { type: "paragraph", content: [{ type: "text", text: $root_cause }] },
          { type: "heading", attrs: { level: 4 }, content: [{ type: "text", text: "How to verify (QA)" }] },
          { type: "orderedList", attrs: { order: 1 }, content: $list_items }
        ] + (if ($commit_info | length) > 0 then [
          { type: "heading", attrs: { level: 4 }, content: [{ type: "text", text: "Build/commit (traceability)" }] },
          { type: "codeBlock", attrs: { language: "text" }, content: [{ type: "text", text: $commit_info }] }
        ] else [] end)
      ) as $content
      | { body: { type: "doc", version: 1, content: $content } }')
  else
    # Plain text for testing steps
    json_payload=$(jq -n \
      --arg root_cause "$root_cause" \
      --arg testing_steps "$testing_steps" \
      --arg commit_info "$commit_info" \
      '(
        [
          { type: "heading", attrs: { level: 3 }, content: [{ type: "text", text: "✅ Ready for QA" }] },
          { type: "heading", attrs: { level: 4 }, content: [{ type: "text", text: "What changed" }] },
          { type: "paragraph", content: [{ type: "text", text: $root_cause }] },
          { type: "heading", attrs: { level: 4 }, content: [{ type: "text", text: "How to verify (QA)" }] },
          { type: "paragraph", content: [{ type: "text", text: $testing_steps }] }
        ] + (if ($commit_info | length) > 0 then [
          { type: "heading", attrs: { level: 4 }, content: [{ type: "text", text: "Build/commit (traceability)" }] },
          { type: "codeBlock", attrs: { language: "text" }, content: [{ type: "text", text: $commit_info }] }
        ] else [] end)
      ) as $content
      | { body: { type: "doc", version: 1, content: $content } }')
  fi
  
  local response
  local api_url
  local http_method
  local expected_code
  
  if [[ -n "$existing_comment_id" ]]; then
    # Update existing comment
    api_url="$JIRA_URL/rest/api/3/issue/$ticket/comment/$existing_comment_id"
    http_method="PUT"
    expected_code="200"
  else
    # Create new comment
    api_url="$JIRA_URL/rest/api/3/issue/$ticket/comment"
    http_method="POST"
    expected_code="201"
  fi
  
  response=$(curl -s -w "\n%{http_code}" \
    -X "$http_method" \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "$api_url")
  
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')
  
  if [[ "$http_code" == "$expected_code" ]]; then
    if [[ -n "$existing_comment_id" ]]; then
      echo -e "${GREEN}✅ Fix details updated on $ticket${NC}"
    else
      echo -e "${GREEN}✅ Fix details added to $ticket${NC}"
    fi
    echo -e "${GREEN}   View at: $JIRA_URL/browse/$ticket${NC}"
    return 0
  else
    echo -e "${RED}❌ Failed to add/update fix details (HTTP $http_code)${NC}"
    echo "$body"
    return 1
  fi
}

# Link a commit to a Jira ticket (adds comment with commit info)
link_commit() {
  local ticket="$1"
  local commit_sha="${2:-HEAD}"
  
  if ! load_config; then
    return 1
  fi
  
  # Resolve commit SHA
  commit_sha=$(git rev-parse "$commit_sha" 2>/dev/null)
  if [[ -z "$commit_sha" ]]; then
    echo -e "${RED}❌ Invalid commit reference${NC}"
    return 1
  fi
  
  local commit_msg
  commit_msg=$(git log -1 --format="%s" "$commit_sha")
  local commit_author
  commit_author=$(git log -1 --format="%an <%ae>" "$commit_sha")
  local commit_date
  commit_date=$(git log -1 --format="%ai" "$commit_sha")
  local files_changed
  files_changed=$(git diff-tree --no-commit-id --name-only -r "$commit_sha" | head -10)
  local file_count
  file_count=$(git diff-tree --no-commit-id --name-only -r "$commit_sha" | wc -l | tr -d ' ')
  
  echo -e "${BLUE}🔗 Linking commit $commit_sha to $ticket...${NC}"
  
  local comment="Commit linked: $commit_sha

Author: $commit_author
Date: $commit_date
Message: $commit_msg

Files changed ($file_count):
$files_changed"

  if [[ "$file_count" -gt 10 ]]; then
    comment+="
... and $((file_count - 10)) more files"
  fi
  
  add_comment "$ticket" "$comment"
}

# Add build/merge info to a Jira ticket
add_build_info() {
  local ticket="$1"
  local build_number="$2"
  local pr_number="$3"
  local pr_title="$4"
  local branch="$5"
  local repo_url="${6:-https://github.com/ThePalaceProject/ios-core}"
  
  if ! load_config; then
    return 1
  fi
  
  if [[ -z "$ticket" || -z "$build_number" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh add-build-info <ticket> <build_number> [pr_number] [pr_title] [branch]${NC}"
    return 1
  fi
  
  echo -e "${BLUE}📦 Adding build info to $ticket...${NC}"
  
  local comment="✅ *Merged to ${branch:-main}*

*Ready for QA:* TestFlight build *${build_number}*
Use the \"How to verify (QA)\" steps in the fix comment above to validate this change."

  if [[ -n "$pr_number" ]]; then
    comment+="

*PR:* [#${pr_number}|${repo_url}/pull/${pr_number}]"
  fi
  
  if [[ -n "$pr_title" ]]; then
    comment+="
*Title:* ${pr_title}"
  fi
  
  add_comment "$ticket" "$comment"
}

# Get Jira link URL for a ticket
get_jira_link() {
  local ticket="$1"
  if ! load_config 2>/dev/null; then
    echo "https://ebce-lyrasis.atlassian.net/browse/$ticket"
  else
    echo "$JIRA_URL/browse/$ticket"
  fi
}

# Interactive fix comment for post-commit hook
interactive_fix_comment() {
  local ticket="$1"
  
  if [[ -z "$ticket" ]]; then
    echo -e "${RED}❌ No ticket provided${NC}"
    return 1
  fi
  
  echo -e "${BLUE}📋 Adding fix details to $ticket${NC}"
  echo ""
  
  echo -e "${YELLOW}Enter what changed (user-facing summary for QA; press Enter twice when done):${NC}"
  local root_cause=""
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    root_cause+="$line\n"
  done
  
  echo ""
  echo -e "${YELLOW}Enter how to verify (QA steps; press Enter twice when done):${NC}"
  local testing_steps=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    testing_steps+="$line\n"
  done
  
  add_fix_comment "$ticket" "$root_cause" "$testing_steps"
}

# ---------------------------------------------------------------------------
# Ticket Management Commands (create, view, search, assign, points, sprint)
# ---------------------------------------------------------------------------

# Get current user's account ID
get_myself() {
  if ! load_config; then
    return 1
  fi

  curl -s \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$JIRA_URL/rest/api/3/myself"
}

# Show current user info
show_myself() {
  local data
  data=$(get_myself) || return 1

  echo "$data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"Account ID: {d['accountId']}\")
print(f\"Name:       {d['displayName']}\")
print(f\"Email:      {d.get('emailAddress', 'N/A')}\")
"
}

# Resolve a user reference to an accountId.
# Accepts: "me", an email address, or a raw accountId.
resolve_user() {
  local user_ref="$1"

  if [[ "$user_ref" == "me" ]]; then
    get_myself | python3 -c "import json,sys; print(json.load(sys.stdin)['accountId'])"
  elif [[ "$user_ref" == *"@"* ]]; then
    # Search by email
    local result
    result=$(curl -s \
      -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
      -H "Content-Type: application/json" \
      --get --data-urlencode "query=$user_ref" \
      "$JIRA_URL/rest/api/3/user/search")
    echo "$result" | python3 -c "
import json, sys
users = json.load(sys.stdin)
if users:
    print(users[0]['accountId'])
else:
    sys.exit(1)
" 2>/dev/null
  else
    # Assume it's already an accountId
    echo "$user_ref"
  fi
}

# Search for tickets by text or JQL
# Uses the POST /rest/api/3/search/jql endpoint (Atlassian deprecated the GET endpoint)
search_tickets() {
  local query="$1"
  local max_results="${2:-10}"

  if ! load_config; then
    return 1
  fi

  if [[ -z "$query" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh search <text|JQL> [max_results]${NC}"
    return 1
  fi

  echo -e "${BLUE}🔍 Searching for: $query${NC}"

  local jql
  # If query looks like JQL (contains = or ORDER BY), use as-is
  if [[ "$query" == *"="* || "$query" == *"ORDER"* || "$query" == *"order"* ]]; then
    jql="$query"
  else
    # Text search within the project
    local project_key="${JIRA_PROJECT_KEY:-PP}"
    jql="project = $project_key AND text ~ \"$query\" ORDER BY updated DESC"
  fi

  local json_payload
  json_payload=$(jq -n \
    --arg jql "$jql" \
    --argjson max "$max_results" \
    '{
      jql: $jql,
      maxResults: $max,
      fields: ["summary", "status", "assignee", "priority", "customfield_10016"]
    }')

  local response
  response=$(curl -s \
    -X POST \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "$JIRA_URL/rest/api/3/search/jql")

  echo "$response" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'errorMessages' in d:
    for e in d['errorMessages']:
        print(f'  Error: {e}')
    sys.exit(1)
issues = d.get('issues', [])
if not issues:
    print('  No results found.')
    sys.exit(0)
print(f'  Found {len(issues)} result(s):')
print()
for issue in issues:
    key = issue['key']
    fields = issue['fields']
    summary = fields.get('summary', '')
    status = fields.get('status', {}).get('name', 'Unknown')
    assignee = fields.get('assignee', {})
    assignee_name = assignee.get('displayName', 'Unassigned') if assignee else 'Unassigned'
    points = fields.get('customfield_10016', '-')
    if points is not None and points != '-':
        points = int(points) if float(points) == int(float(points)) else points
    priority = fields.get('priority', {}).get('name', '-')
    print(f'  {key}  [{status}]  {priority}  {points}pts  @{assignee_name}')
    print(f'    {summary}')
    print()
" 2>/dev/null || {
    echo -e "${RED}❌ Search failed${NC}"
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
    return 1
  }
}

# View a single ticket's details
view_ticket() {
  local ticket="$1"

  if ! load_config; then
    return 1
  fi

  if [[ -z "$ticket" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh view <ticket>${NC}"
    return 1
  fi

  local response
  response=$(curl -s \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$JIRA_URL/rest/api/3/issue/$ticket?fields=summary,status,assignee,priority,customfield_10016,issuetype,sprint,created,updated,description,labels")

  local http_code
  http_code=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'key' in d else 1)" 2>/dev/null && echo "200" || echo "404")

  if [[ "$http_code" != "200" ]]; then
    echo -e "${RED}❌ Ticket $ticket not found${NC}"
    return 1
  fi

  echo "$response" | python3 -c "
import json, sys
d = json.load(sys.stdin)
f = d['fields']
print(f\"Ticket:     {d['key']}\")
print(f\"Type:       {f.get('issuetype', {}).get('name', '-')}\")
print(f\"Summary:    {f.get('summary', '-')}\")
print(f\"Status:     {f.get('status', {}).get('name', '-')}\")
print(f\"Priority:   {f.get('priority', {}).get('name', '-')}\")
a = f.get('assignee')
print(f\"Assignee:   {a['displayName'] if a else 'Unassigned'}\")
print(f\"Points:     {f.get('customfield_10016', '-')}\")
labels = f.get('labels', [])
print(f\"Labels:     {', '.join(labels) if labels else '-'}\")
print(f\"Created:    {f.get('created', '-')[:10]}\")
print(f\"Updated:    {f.get('updated', '-')[:10]}\")
print(f\"URL:        ${JIRA_URL}/browse/{d['key']}\")

# Print description (first 500 chars of plain text)
desc = f.get('description')
if desc:
    def extract_text(node):
        texts = []
        if isinstance(node, dict):
            if node.get('type') == 'text':
                texts.append(node.get('text', ''))
            for child in node.get('content', []):
                texts.extend(extract_text(child))
        return texts
    text = ' '.join(extract_text(desc)).strip()
    if text:
        print(f\"\\nDescription:\\n  {text[:500]}{'...' if len(text) > 500 else ''}\")
" 2>/dev/null
}

# Create a new Jira ticket
# Usage: create_ticket <type> <summary> [description]
# type: bug, task, story
create_ticket() {
  local issue_type="$1"
  local summary="$2"
  local description="${3:-}"

  if ! load_config; then
    return 1
  fi

  if [[ -z "$issue_type" || -z "$summary" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh create <bug|task|story> <summary> [description]${NC}"
    return 1
  fi

  # Map type name to Jira issue type ID
  local type_id
  case "$(echo "$issue_type" | tr '[:upper:]' '[:lower:]')" in
    bug)   type_id="10014" ;;
    task)  type_id="10012" ;;
    story) type_id="10009" ;;
    *)
      echo -e "${RED}❌ Unknown issue type: $issue_type. Use: bug, task, story${NC}"
      return 1
      ;;
  esac

  local project_key="${JIRA_PROJECT_KEY:-PP}"
  echo -e "${BLUE}📝 Creating $issue_type in $project_key: $summary${NC}"

  # Build description ADF if provided
  local desc_json="null"
  if [[ -n "$description" ]]; then
    desc_json=$(jq -n --arg text "$description" '{
      type: "doc",
      version: 1,
      content: [
        {
          type: "paragraph",
          content: [{ type: "text", text: $text }]
        }
      ]
    }')
  fi

  local json_payload
  json_payload=$(jq -n \
    --arg project_key "$project_key" \
    --arg type_id "$type_id" \
    --arg summary "$summary" \
    --argjson description "$desc_json" \
    '{
      fields: {
        project: { key: $project_key },
        issuetype: { id: $type_id },
        summary: $summary
      }
    } | if $description != null then .fields.description = $description else . end')

  local response
  response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "$JIRA_URL/rest/api/3/issue")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "201" ]]; then
    local ticket_key
    ticket_key=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
    echo -e "${GREEN}✅ Created $ticket_key${NC}"
    echo -e "${GREEN}   $JIRA_URL/browse/$ticket_key${NC}"
    # Return the key for scripting
    echo "$ticket_key"
    return 0
  else
    echo -e "${RED}❌ Failed to create ticket (HTTP $http_code)${NC}"
    echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
    return 1
  fi
}

# Assign a ticket to a user
# Usage: assign_ticket <ticket> <user>
# user: "me", an email address, or an accountId
assign_ticket() {
  local ticket="$1"
  local user_ref="$2"

  if ! load_config; then
    return 1
  fi

  if [[ -z "$ticket" || -z "$user_ref" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh assign <ticket> <me|email|accountId>${NC}"
    return 1
  fi

  echo -e "${BLUE}👤 Assigning $ticket to $user_ref...${NC}"

  local account_id
  account_id=$(resolve_user "$user_ref")
  if [[ -z "$account_id" ]]; then
    echo -e "${RED}❌ Could not resolve user: $user_ref${NC}"
    return 1
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"fields\": {\"assignee\": {\"accountId\": \"$account_id\"}}}" \
    "$JIRA_URL/rest/api/3/issue/$ticket")

  if [[ "$http_code" == "204" ]]; then
    echo -e "${GREEN}✅ $ticket assigned${NC}"
    return 0
  else
    echo -e "${RED}❌ Failed to assign $ticket (HTTP $http_code)${NC}"
    return 1
  fi
}

# Set story points on a ticket
# Usage: set_points <ticket> <points>
set_points() {
  local ticket="$1"
  local points="$2"

  if ! load_config; then
    return 1
  fi

  if [[ -z "$ticket" || -z "$points" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh set-points <ticket> <points>${NC}"
    return 1
  fi

  echo -e "${BLUE}🎯 Setting $ticket to $points point(s)...${NC}"

  # customfield_10016 = "Story point estimate" in this Jira instance
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"fields\": {\"customfield_10016\": $points}}" \
    "$JIRA_URL/rest/api/3/issue/$ticket")

  if [[ "$http_code" == "204" ]]; then
    echo -e "${GREEN}✅ $ticket set to $points point(s)${NC}"
    return 0
  else
    echo -e "${RED}❌ Failed to set points on $ticket (HTTP $http_code)${NC}"
    return 1
  fi
}

# List sprints for the PP board
# Usage: get_sprints [active|future|closed]
get_sprints() {
  local state="${1:-active}"

  if ! load_config; then
    return 1
  fi

  # Board ID 4 = "PP board" (scrum board for The Palace Project)
  local board_id=4
  echo -e "${BLUE}📋 Sprints (state: $state):${NC}"

  local response
  response=$(curl -s \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$JIRA_URL/rest/agile/1.0/board/$board_id/sprint?state=$state")

  echo "$response" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sprints = d.get('values', [])
if not sprints:
    print('  No sprints found.')
    sys.exit(0)
for s in sprints:
    start = s.get('startDate', '-')[:10] if s.get('startDate') else '-'
    end = s.get('endDate', '-')[:10] if s.get('endDate') else '-'
    print(f\"  {s['name']}  (id: {s['id']})  [{s['state']}]  {start} -> {end}\")
" 2>/dev/null || {
    echo -e "${RED}❌ Failed to fetch sprints${NC}"
    echo "$response"
    return 1
  }
}

# Move a ticket to a sprint
# Usage: move_to_sprint <ticket> <sprint_id|current>
move_to_sprint() {
  local ticket="$1"
  local sprint_ref="$2"

  if ! load_config; then
    return 1
  fi

  if [[ -z "$ticket" || -z "$sprint_ref" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh move-to-sprint <ticket> <sprint_id|current>${NC}"
    return 1
  fi

  local sprint_id
  if [[ "$sprint_ref" == "current" || "$sprint_ref" == "active" ]]; then
    # Find the active sprint
    local board_id=4
    sprint_id=$(curl -s \
      -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
      -H "Content-Type: application/json" \
      "$JIRA_URL/rest/agile/1.0/board/$board_id/sprint?state=active" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['values'][0]['id'])" 2>/dev/null)

    if [[ -z "$sprint_id" ]]; then
      echo -e "${RED}❌ No active sprint found${NC}"
      return 1
    fi
    echo -e "${BLUE}📌 Moving $ticket to active sprint (id: $sprint_id)...${NC}"
  else
    sprint_id="$sprint_ref"
    echo -e "${BLUE}📌 Moving $ticket to sprint $sprint_id...${NC}"
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"issues\": [\"$ticket\"]}" \
    "$JIRA_URL/rest/agile/1.0/sprint/$sprint_id/issue")

  if [[ "$http_code" == "204" ]]; then
    echo -e "${GREEN}✅ $ticket moved to sprint${NC}"
    return 0
  else
    echo -e "${RED}❌ Failed to move $ticket to sprint (HTTP $http_code)${NC}"
    return 1
  fi
}

# Batch update: assign + points + sprint + transition in one call
# Usage: batch_update <ticket> [--assign me] [--points 3] [--sprint current] [--transition "Code Review"]
batch_update() {
  local ticket="$1"
  shift

  if ! load_config; then
    return 1
  fi

  if [[ -z "$ticket" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh batch-update <ticket> [--assign user] [--points N] [--sprint id|current] [--transition status]${NC}"
    return 1
  fi

  local assign_ref="" points="" sprint_ref="" transition_status=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --assign)    assign_ref="$2"; shift 2 ;;
      --points)    points="$2"; shift 2 ;;
      --sprint)    sprint_ref="$2"; shift 2 ;;
      --transition) transition_status="$2"; shift 2 ;;
      *) echo -e "${YELLOW}⚠️  Unknown option: $1${NC}"; shift ;;
    esac
  done

  echo -e "${BLUE}🔄 Batch updating $ticket...${NC}"
  local had_error=0

  # 1. Assign + points in a single PUT if both provided
  if [[ -n "$assign_ref" || -n "$points" ]]; then
    local fields_json="{"
    local comma=""

    if [[ -n "$assign_ref" ]]; then
      local account_id
      account_id=$(resolve_user "$assign_ref")
      if [[ -n "$account_id" ]]; then
        fields_json+="\"assignee\": {\"accountId\": \"$account_id\"}"
        comma=","
      else
        echo -e "${RED}   ❌ Could not resolve user: $assign_ref${NC}"
        had_error=1
      fi
    fi

    if [[ -n "$points" ]]; then
      fields_json+="${comma}\"customfield_10016\": $points"
    fi

    fields_json+="}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PUT \
      -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"fields\": $fields_json}" \
      "$JIRA_URL/rest/api/3/issue/$ticket")

    if [[ "$http_code" == "204" ]]; then
      [[ -n "$assign_ref" ]] && echo -e "${GREEN}   ✅ Assigned to $assign_ref${NC}"
      [[ -n "$points" ]] && echo -e "${GREEN}   ✅ Set to $points point(s)${NC}"
    else
      echo -e "${RED}   ❌ Failed to update fields (HTTP $http_code)${NC}"
      had_error=1
    fi
  fi

  # 2. Move to sprint
  if [[ -n "$sprint_ref" ]]; then
    move_to_sprint "$ticket" "$sprint_ref" > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      echo -e "${GREEN}   ✅ Moved to sprint${NC}"
    else
      echo -e "${RED}   ❌ Failed to move to sprint${NC}"
      had_error=1
    fi
  fi

  # 3. Transition
  if [[ -n "$transition_status" ]]; then
    transition_ticket "$ticket" "$transition_status" > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      echo -e "${GREEN}   ✅ Transitioned to '$transition_status'${NC}"
    else
      echo -e "${RED}   ❌ Failed to transition to '$transition_status'${NC}"
      had_error=1
    fi
  fi

  if [[ "$had_error" -eq 0 ]]; then
    echo -e "${GREEN}✅ $ticket fully updated${NC}"
  else
    echo -e "${YELLOW}⚠️  $ticket partially updated (some operations failed)${NC}"
  fi
  return $had_error
}

# Main command dispatcher
main() {
  local command="$1"
  shift || true
  
  case "$command" in
    # --- Ticket lifecycle ---
    search)
      search_tickets "$@"
      ;;
    view)
      view_ticket "$@"
      ;;
    create)
      create_ticket "$@"
      ;;
    assign)
      assign_ticket "$@"
      ;;
    set-points)
      set_points "$@"
      ;;
    move-to-sprint)
      move_to_sprint "$@"
      ;;
    transition)
      transition_ticket "$@"
      ;;
    batch-update)
      batch_update "$@"
      ;;
    # --- Comments & linking ---
    comment)
      add_comment "$@"
      ;;
    link-commit)
      link_commit "$@"
      ;;
    add-fix-comment)
      add_fix_comment "$@"
      ;;
    add-build-info)
      add_build_info "$@"
      ;;
    interactive)
      interactive_fix_comment "$@"
      ;;
    # --- Utilities ---
    get-sprints)
      get_sprints "$@"
      ;;
    whoami)
      show_myself
      ;;
    extract-ticket)
      extract_ticket "$@"
      ;;
    get-link)
      get_jira_link "$@"
      ;;
    check-config)
      load_config && echo -e "${GREEN}✅ Configuration valid${NC}"
      ;;
    *)
      echo "Jira Integration Script for Palace iOS"
      echo ""
      echo "Usage: $0 <command> [arguments]"
      echo ""
      echo "Ticket Lifecycle:"
      echo "  search <text|JQL> [max]          Search for existing tickets"
      echo "  view <ticket>                     View ticket details"
      echo "  create <bug|task|story> <summary> [description]"
      echo "                                    Create a new ticket"
      echo "  assign <ticket> <me|email|id>     Assign ticket to a user"
      echo "  set-points <ticket> <points>      Set story points"
      echo "  move-to-sprint <ticket> <id|current>"
      echo "                                    Move ticket to a sprint"
      echo "  transition <ticket> <status>      Change status (e.g., 'Code Review', 'Done')"
      echo "  batch-update <ticket> [--assign me] [--points 3] [--sprint current] [--transition status]"
      echo "                                    Update multiple fields at once"
      echo ""
      echo "Comments & Linking:"
      echo "  comment <ticket> <text>           Add a comment to a ticket"
      echo "  link-commit <ticket> [sha]        Link a commit to a ticket"
      echo "  add-fix-comment <ticket> <what_changed> <how_to_verify_qa> [sha]"
      echo "                                    Add structured fix details"
      echo "  add-build-info <ticket> <build> [pr_num] [pr_title] [branch]"
      echo "                                    Add merge/build info to ticket"
      echo "  interactive <ticket>              Interactive fix comment entry"
      echo ""
      echo "Utilities:"
      echo "  get-sprints [active|future|closed] List sprints"
      echo "  whoami                            Show current user info"
      echo "  extract-ticket <text>             Extract ticket number from text"
      echo "  get-link <ticket>                 Get Jira URL for ticket"
      echo "  check-config                      Verify configuration"
      echo ""
      echo "Setup:"
      echo "  1. Copy .jira-config.template to .jira-config"
      echo "  2. Fill in your Jira credentials"
      echo "  3. Generate API token at: https://id.atlassian.com/manage-profile/security/api-tokens"
      ;;
  esac
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
