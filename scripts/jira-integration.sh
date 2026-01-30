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
build_list_items() {
  local text="$1"
  
  # First, normalize the text: replace literal \n with actual newlines
  text=$(echo -e "$text")
  
  # Split by numbered pattern (1. 2. 3. etc) - insert newline before each number
  # Then process each line to strip the number prefix
  echo "$text" | sed 's/[0-9]\+\.\s*/\n/g' | while IFS= read -r line; do
    # Trim whitespace
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Skip empty lines and lines that are just numbers
    if [[ -n "$line" && ! "$line" =~ ^[0-9]+\.?$ ]]; then
      # Also strip any remaining leading numbers (handles "1. 1. text" cases)
      line=$(echo "$line" | sed 's/^[0-9]\+\.\s*//')
      if [[ -n "$line" ]]; then
        echo "$line"
      fi
    fi
  done
}

# Find existing "Fix Details" comment ID for a ticket
find_fix_comment_id() {
  local ticket="$1"
  
  local response
  response=$(curl -s \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$JIRA_URL/rest/api/3/issue/$ticket/comment")
  
  # Find comment containing "Fix Details" and return its ID
  echo "$response" | jq -r '.comments[]? | select(.body.content[]?.content[]?.text? | contains("Fix Details")) | .id' | head -1
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
  if [[ "$list_items_json" != "[]" ]]; then
    # Use ordered list for testing steps
    json_payload=$(jq -n \
      --arg root_cause "$root_cause" \
      --argjson list_items "$list_items_json" \
      --arg commit_info "$commit_info" \
      '{
        body: {
          type: "doc",
          version: 1,
          content: [
            {
              type: "heading",
              attrs: { level: 3 },
              content: [{ type: "text", text: "🔧 Fix Details" }]
            },
            {
              type: "heading", 
              attrs: { level: 4 },
              content: [{ type: "text", text: "Root Cause" }]
            },
            {
              type: "paragraph",
              content: [{ type: "text", text: $root_cause }]
            },
            {
              type: "heading",
              attrs: { level: 4 },
              content: [{ type: "text", text: "Testing Steps" }]
            },
            {
              type: "orderedList",
              attrs: { order: 1 },
              content: $list_items
            },
            {
              type: "heading",
              attrs: { level: 4 },
              content: [{ type: "text", text: "Commit Information" }]
            },
            {
              type: "codeBlock",
              attrs: { language: "text" },
              content: [{ type: "text", text: $commit_info }]
            }
          ]
        }
      }')
  else
    # Plain text for testing steps
    json_payload=$(jq -n \
      --arg root_cause "$root_cause" \
      --arg testing_steps "$testing_steps" \
      --arg commit_info "$commit_info" \
      '{
        body: {
          type: "doc",
          version: 1,
          content: [
            {
              type: "heading",
              attrs: { level: 3 },
              content: [{ type: "text", text: "🔧 Fix Details" }]
            },
            {
              type: "heading", 
              attrs: { level: 4 },
              content: [{ type: "text", text: "Root Cause" }]
            },
            {
              type: "paragraph",
              content: [{ type: "text", text: $root_cause }]
            },
            {
              type: "heading",
              attrs: { level: 4 },
              content: [{ type: "text", text: "Testing Steps" }]
            },
            {
              type: "paragraph",
              content: [{ type: "text", text: $testing_steps }]
            },
            {
              type: "heading",
              attrs: { level: 4 },
              content: [{ type: "text", text: "Commit Information" }]
            },
            {
              type: "codeBlock",
              attrs: { language: "text" },
              content: [{ type: "text", text: $commit_info }]
            }
          ]
        }
      }')
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
