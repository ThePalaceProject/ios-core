#!/usr/bin/env bash
#
# run_diff.sh - Run ledger diff analysis on Palace iOS
#
# This script:
#   1. Installs ledger (if needed)
#   2. Runs diff analysis comparing main..HEAD
#   3. Generates spec diff
#   4. Writes a summary
#
# Usage:
#   ./tools/ledger/run_diff.sh
#   BASE_REF=develop ./tools/ledger/run_diff.sh  # Custom base
#
# Environment:
#   BASE_REF  - Base branch/commit (default: main)
#   HEAD_REF  - Head branch/commit (default: HEAD)
#
# Output:
#   artifacts/ledger/diff/     - Diff analysis output
#   artifacts/ledger/logs/     - Diff summary

set -euo pipefail

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEDGER_BIN="${REPO_ROOT}/tools/bin/ledger"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts/ledger"
DOMAINS="arch,reach,a11y"

# Git refs
BASE_REF="${BASE_REF:-main}"
HEAD_REF="${HEAD_REF:-HEAD}"
DIFF_RANGE="${BASE_REF}..${HEAD_REF}"

# Timestamp
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# -----------------------------------------------------------------
# Colors
# -----------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${CI:-}" ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    GREEN='' BLUE='' YELLOW='' NC=''
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

# -----------------------------------------------------------------
# Install ledger
# -----------------------------------------------------------------
log_info "Ensuring ledger is installed..."
"${SCRIPT_DIR}/install_ledger.sh"
echo ""

# Verify ledger is available
if [[ ! -x "$LEDGER_BIN" ]]; then
    echo "ERROR: Ledger binary not found at ${LEDGER_BIN}"
    exit 1
fi

LEDGER_VERSION=$("$LEDGER_BIN" --version 2>&1 | head -1 || echo "unknown")

# -----------------------------------------------------------------
# Initialize and update ledger if needed
# -----------------------------------------------------------------
if [[ ! -f "${REPO_ROOT}/.ledger/config.json" ]]; then
    log_info "Initializing ledger for this repository..."
    "$LEDGER_BIN" init --repo "${REPO_ROOT}" --no-interactive 2>&1 || {
        log_info "Note: Ledger initialization completed with warnings"
    }
    echo ""
fi

if [[ ! -f "${REPO_ROOT}/.ledger/model.json" ]]; then
    log_info "Building initial ledger model (this may take a moment)..."
    "$LEDGER_BIN" update --repo "${REPO_ROOT}" 2>&1 || {
        log_info "Note: Model update completed with warnings"
    }
    echo ""
fi

# -----------------------------------------------------------------
# Validate git refs
# -----------------------------------------------------------------
log_info "Validating git refs..."

cd "$REPO_ROOT"

if ! git rev-parse --verify "${BASE_REF}" >/dev/null 2>&1; then
    log_warn "Base ref '${BASE_REF}' not found locally"
    log_info "Attempting to fetch origin/${BASE_REF}..."
    git fetch origin "${BASE_REF}" 2>/dev/null || {
        log_warn "Could not fetch ${BASE_REF}, using origin/main as fallback"
        BASE_REF="origin/main"
    }
fi

if ! git rev-parse --verify "${HEAD_REF}" >/dev/null 2>&1; then
    log_warn "Head ref '${HEAD_REF}' not found"
    HEAD_REF="HEAD"
fi

DIFF_RANGE="${BASE_REF}..${HEAD_REF}"
log_info "Diff range: ${DIFF_RANGE}"

# Show changed files
CHANGED_FILES=$(git diff --name-only "${DIFF_RANGE}" 2>/dev/null | wc -l | tr -d ' ')
log_info "Changed files: ${CHANGED_FILES}"
echo ""

# -----------------------------------------------------------------
# Setup directories
# -----------------------------------------------------------------
log_info "Setting up artifacts directories..."
mkdir -p "${ARTIFACTS_DIR}/diff"
mkdir -p "${ARTIFACTS_DIR}/logs"

# -----------------------------------------------------------------
# Run spec diff
# -----------------------------------------------------------------
log_info "Running spec diff..."
log_info "  Base: ${BASE_REF}"
log_info "  Head: ${HEAD_REF}"
echo ""

"$LEDGER_BIN" spec diff \
    --base "${BASE_REF}" \
    --head "${HEAD_REF}" \
    --format md \
    --output "${ARTIFACTS_DIR}/diff/spec-diff.md" \
    --repo "${REPO_ROOT}" \
    2>&1 | tee "${ARTIFACTS_DIR}/logs/spec-diff-${TIMESTAMP}.log" || {
        log_info "Note: Spec diff completed with warnings (may indicate no spec changes)"
    }

echo ""

# -----------------------------------------------------------------
# Run analysis on current state
# -----------------------------------------------------------------
log_info "Running architecture analysis..."
log_info "  Domains: ${DOMAINS}"
echo ""

"$LEDGER_BIN" analyze \
    --repo "${REPO_ROOT}" \
    --domains "${DOMAINS}" \
    --write \
    2>&1 | tee "${ARTIFACTS_DIR}/logs/diff-analyze-${TIMESTAMP}.log" || {
        log_info "Note: Analysis completed with warnings"
    }

# Copy analysis output to diff artifacts
if [[ -f "${REPO_ROOT}/docs/ledger/ANALYSIS.md" ]]; then
    cp "${REPO_ROOT}/docs/ledger/ANALYSIS.md" "${ARTIFACTS_DIR}/diff/"
fi

echo ""

# -----------------------------------------------------------------
# Generate summary
# -----------------------------------------------------------------
SUMMARY_FILE="${ARTIFACTS_DIR}/logs/diff-summary.md"

log_info "Generating diff summary..."

# Get commit info
BASE_SHA=$(git rev-parse --short "${BASE_REF}" 2>/dev/null || echo "unknown")
HEAD_SHA=$(git rev-parse --short "${HEAD_REF}" 2>/dev/null || echo "unknown")

cat > "$SUMMARY_FILE" << EOF
# Ledger Diff Analysis Summary

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Ledger Version:** ${LEDGER_VERSION}

## Diff Range

| Ref | Commit |
|-----|--------|
| Base (${BASE_REF}) | ${BASE_SHA} |
| Head (${HEAD_REF}) | ${HEAD_SHA} |

**Changed files:** ${CHANGED_FILES}

## Configuration

| Setting | Value |
|---------|-------|
| Domains | ${DOMAINS} |
| Diff Range | ${DIFF_RANGE} |

## Artifacts

| Type | Location |
|------|----------|
| Spec Diff | \`artifacts/ledger/diff/spec-diff.md\` |
| Analysis | \`artifacts/ledger/diff/ANALYSIS.md\` |

## Changed Files

\`\`\`
$(git diff --name-only "${DIFF_RANGE}" 2>/dev/null | head -20 || echo "(unable to list)")
\`\`\`
$(if [[ ${CHANGED_FILES} -gt 20 ]]; then echo "... and $((CHANGED_FILES - 20)) more files"; fi)

## Logs

- Spec diff: \`artifacts/ledger/logs/spec-diff-${TIMESTAMP}.log\`
- Analysis: \`artifacts/ledger/logs/diff-analyze-${TIMESTAMP}.log\`
EOF

echo ""
log_success "Diff analysis complete!"
echo ""
echo "Summary written to: ${SUMMARY_FILE}"
echo ""
echo "Artifacts:"
echo "  Spec diff: ${ARTIFACTS_DIR}/diff/spec-diff.md"
echo "  Analysis: ${ARTIFACTS_DIR}/diff/ANALYSIS.md"
echo "  Logs: ${ARTIFACTS_DIR}/logs/"
