#!/usr/bin/env bash
#
# run_full.sh - Run full ledger analysis on Palace iOS
#
# This script:
#   1. Installs ledger (if needed)
#   2. Runs full codebase analysis
#   3. Builds specification artifacts
#   4. Generates a run summary
#
# Usage:
#   ./tools/ledger/run_full.sh
#
# Output:
#   artifacts/ledger/full/     - Full analysis output
#   artifacts/ledger/spec/     - Specification artifacts
#   artifacts/ledger/latest/   - Copy of latest outputs
#   artifacts/ledger/logs/     - Run summaries

set -euo pipefail

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEDGER_BIN="${REPO_ROOT}/tools/bin/ledger"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts/ledger"
DOMAINS="arch,reach,a11y"

# Timestamp for this run
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# -----------------------------------------------------------------
# Colors
# -----------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${CI:-}" ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    GREEN='' BLUE='' NC=''
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

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
# Setup directories
# -----------------------------------------------------------------
log_info "Setting up artifacts directories..."
mkdir -p "${ARTIFACTS_DIR}/full"
mkdir -p "${ARTIFACTS_DIR}/spec"
mkdir -p "${ARTIFACTS_DIR}/latest"
mkdir -p "${ARTIFACTS_DIR}/logs"

# -----------------------------------------------------------------
# Run full analysis
# -----------------------------------------------------------------
log_info "Running full codebase analysis..."
log_info "  Domains: ${DOMAINS}"
log_info "  Output:  ${ARTIFACTS_DIR}/full"
echo ""

cd "${REPO_ROOT}"

# Run analyze with --write flag (writes to docs/ledger/ANALYSIS.md)
"$LEDGER_BIN" analyze \
    --repo "${REPO_ROOT}" \
    --domains "${DOMAINS}" \
    --write \
    2>&1 | tee "${ARTIFACTS_DIR}/logs/analyze-${TIMESTAMP}.log" || {
        log_info "Note: Analysis completed with warnings (this is normal for first run)"
    }

# Copy analysis output to artifacts
if [[ -f "${REPO_ROOT}/docs/ledger/ANALYSIS.md" ]]; then
    cp "${REPO_ROOT}/docs/ledger/ANALYSIS.md" "${ARTIFACTS_DIR}/full/"
fi

echo ""

# -----------------------------------------------------------------
# Build specifications
# -----------------------------------------------------------------
log_info "Building specification artifacts..."
log_info "  Output: ${ARTIFACTS_DIR}/spec"
echo ""

# Generate markdown spec
"$LEDGER_BIN" spec build \
    --repo "${REPO_ROOT}" \
    --domains "${DOMAINS}" \
    --format md \
    --output "${ARTIFACTS_DIR}/spec" \
    2>&1 | tee "${ARTIFACTS_DIR}/logs/spec-build-${TIMESTAMP}.log" || {
        log_info "Note: Spec build (md) completed with warnings"
    }

# Generate JSON spec (needed for verification)
"$LEDGER_BIN" spec build \
    --repo "${REPO_ROOT}" \
    --domains "${DOMAINS}" \
    --format json \
    --output "${ARTIFACTS_DIR}/spec" \
    2>&1 | tee -a "${ARTIFACTS_DIR}/logs/spec-build-${TIMESTAMP}.log" || {
        log_info "Note: Spec build (json) completed with warnings"
    }

echo ""

# -----------------------------------------------------------------
# Copy to latest
# -----------------------------------------------------------------
log_info "Updating latest artifacts..."
rm -rf "${ARTIFACTS_DIR}/latest/full" "${ARTIFACTS_DIR}/latest/spec"
cp -R "${ARTIFACTS_DIR}/full" "${ARTIFACTS_DIR}/latest/full" 2>/dev/null || true
cp -R "${ARTIFACTS_DIR}/spec" "${ARTIFACTS_DIR}/latest/spec" 2>/dev/null || true

# -----------------------------------------------------------------
# Generate summary
# -----------------------------------------------------------------
SUMMARY_FILE="${ARTIFACTS_DIR}/logs/run-summary.md"

log_info "Generating run summary..."

# Count findings if output exists
ARCH_COUNT=0
REACH_COUNT=0
A11Y_COUNT=0

if [[ -d "${ARTIFACTS_DIR}/full" ]]; then
    ARCH_COUNT=$(grep -l "arch" "${ARTIFACTS_DIR}/full"/*.md 2>/dev/null | wc -l | tr -d ' ') || true
    REACH_COUNT=$(grep -l "reach" "${ARTIFACTS_DIR}/full"/*.md 2>/dev/null | wc -l | tr -d ' ') || true
    A11Y_COUNT=$(grep -l "a11y" "${ARTIFACTS_DIR}/full"/*.md 2>/dev/null | wc -l | tr -d ' ') || true
fi

cat > "$SUMMARY_FILE" << EOF
# Ledger Analysis Summary

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Ledger Version:** ${LEDGER_VERSION}

## Configuration

| Setting | Value |
|---------|-------|
| Domains | ${DOMAINS} |
| Repository | ${REPO_ROOT} |

## Artifacts

| Type | Location |
|------|----------|
| Full Analysis | \`artifacts/ledger/full/\` |
| Specifications | \`artifacts/ledger/spec/\` |
| Latest (copy) | \`artifacts/ledger/latest/\` |
| Logs | \`artifacts/ledger/logs/\` |

## Findings Overview

| Domain | Files with Findings |
|--------|---------------------|
| Architecture (arch) | ${ARCH_COUNT} |
| Reachability (reach) | ${REACH_COUNT} |
| Accessibility (a11y) | ${A11Y_COUNT} |

## Next Steps

1. Review findings in \`artifacts/ledger/full/\`
2. Check specifications in \`artifacts/ledger/spec/\`
3. Run \`./tools/ledger/run_verify.sh\` to verify against specs

## Logs

- Analysis log: \`artifacts/ledger/logs/analyze-${TIMESTAMP}.log\`
- Spec build log: \`artifacts/ledger/logs/spec-build-${TIMESTAMP}.log\`
EOF

echo ""
log_success "Full analysis complete!"
echo ""
echo "Summary written to: ${SUMMARY_FILE}"
echo ""
echo "Artifacts:"
echo "  Full analysis: ${ARTIFACTS_DIR}/full/"
echo "  Specifications: ${ARTIFACTS_DIR}/spec/"
echo "  Latest: ${ARTIFACTS_DIR}/latest/"
echo "  Logs: ${ARTIFACTS_DIR}/logs/"
