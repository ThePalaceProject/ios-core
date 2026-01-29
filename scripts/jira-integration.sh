#!/bin/bash
#
# Jira Integration Script for Palace iOS
# 
# This script provides functions to interact with Jira:
# - Extract ticket numbers from commit messages
# - Add comments to Jira tickets
# - Link commits to tickets
#
# Usage:
#   ./jira-integration.sh comment PP-3605 "Your comment here"
#   ./jira-integration.sh link-commit PP-3605 <commit-sha>
#   ./jira-integration.sh add-fix-comment PP-3605 "Root cause" "Testing steps"
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
  
  # Jira API v3 uses Atlassian Document Format (ADF)
  local json_payload
  json_payload=$(cat <<EOF
{
  "body": {
    "type": "doc",
    "version": 1,
    "content": [
      {
        "type": "paragraph",
        "content": [
          {
            "type": "text",
            "text": "$comment"
          }
        ]
      }
    ]
  }
}
EOF
)
  
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

# Add a structured fix comment with root cause and testing steps
add_fix_comment() {
  local ticket="$1"
  local root_cause="$2"
  local testing_steps="$3"
  local commit_sha="${4:-$(git rev-parse HEAD 2>/dev/null || echo '')}"
  
  if ! load_config; then
    return 1
  fi
  
  if [[ -z "$ticket" ]]; then
    echo -e "${RED}❌ Usage: jira-integration.sh add-fix-comment <ticket> <root_cause> <testing_steps> [commit_sha]${NC}"
    return 1
  fi
  
  echo -e "${BLUE}📝 Adding fix details to $ticket...${NC}"
  
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
      commit_info="Commit: $commit_sha\nAuthor: $commit_author\nDate: $commit_date\nMessage: $commit_msg"
    fi
  fi
  
  # Build the comment content
  local content_blocks='['
  
  # Header
  content_blocks+='{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"🔧 Fix Details"}]},'
  
  # Root Cause section
  if [[ -n "$root_cause" ]]; then
    content_blocks+='{"type":"heading","attrs":{"level":4},"content":[{"type":"text","text":"Root Cause"}]},'
    content_blocks+='{"type":"paragraph","content":[{"type":"text","text":"'"$(echo "$root_cause" | sed 's/"/\\"/g' | sed 's/\n/\\n/g')"'"}]},'
  fi
  
  # Testing Steps section
  if [[ -n "$testing_steps" ]]; then
    content_blocks+='{"type":"heading","attrs":{"level":4},"content":[{"type":"text","text":"Testing Steps"}]},'
    content_blocks+='{"type":"paragraph","content":[{"type":"text","text":"'"$(echo "$testing_steps" | sed 's/"/\\"/g' | sed 's/\n/\\n/g')"'"}]},'
  fi
  
  # Commit info section
  if [[ -n "$commit_info" ]]; then
    content_blocks+='{"type":"heading","attrs":{"level":4},"content":[{"type":"text","text":"Commit Information"}]},'
    content_blocks+='{"type":"codeBlock","attrs":{"language":"text"},"content":[{"type":"text","text":"'"$(echo -e "$commit_info" | sed 's/"/\\"/g')"'"}]},'
  fi
  
  # Remove trailing comma and close array
  content_blocks="${content_blocks%,}]"
  
  local json_payload
  json_payload=$(cat <<EOF
{
  "body": {
    "type": "doc",
    "version": 1,
    "content": $content_blocks
  }
}
EOF
)
  
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
    echo -e "${GREEN}✅ Fix details added to $ticket${NC}"
    echo -e "${GREEN}   View at: $JIRA_URL/browse/$ticket${NC}"
    return 0
  else
    echo -e "${RED}❌ Failed to add fix details (HTTP $http_code)${NC}"
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
  
  echo -e "${YELLOW}Enter root cause (press Enter twice when done):${NC}"
  local root_cause=""
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    root_cause+="$line\n"
  done
  
  echo ""
  echo -e "${YELLOW}Enter testing steps (press Enter twice when done):${NC}"
  local testing_steps=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    testing_steps+="$line\n"
  done
  
  add_fix_comment "$ticket" "$root_cause" "$testing_steps"
}

# Main command dispatcher
main() {
  local command="$1"
  shift || true
  
  case "$command" in
    comment)
      add_comment "$@"
      ;;
    link-commit)
      link_commit "$@"
      ;;
    add-fix-comment)
      add_fix_comment "$@"
      ;;
    interactive)
      interactive_fix_comment "$@"
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
      echo "Commands:"
      echo "  comment <ticket> <text>           Add a comment to a ticket"
      echo "  link-commit <ticket> [sha]        Link a commit to a ticket"
      echo "  add-fix-comment <ticket> <root_cause> <testing_steps> [sha]"
      echo "                                    Add structured fix details"
      echo "  interactive <ticket>              Interactive fix comment entry"
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
