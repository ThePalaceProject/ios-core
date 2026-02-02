#!/usr/bin/env bash
#
# run_verify.sh - Verify Palace iOS codebase against ledger specs
#
# This script:
#   1. Installs ledger (if needed)
#   2. Checks for existing spec artifacts
#   3. Runs verification against specs
#
# Usage:
#   ./tools/ledger/run_verify.sh
#
# Prerequisites:
#   Run ./tools/ledger/run_full.sh first to generate specs
#
# Output:
#   Verification results to stdout
#   Exit code indicates pass/fail

set -euo pipefail

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEDGER_BIN="${REPO_ROOT}/tools/bin/ledger"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts/ledger"
SPEC_DIR="${ARTIFACTS_DIR}/spec"

# -----------------------------------------------------------------
# Colors
# -----------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${CI:-}" ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN='' BLUE='' YELLOW='' RED='' NC=''
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

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
log_info "Ledger version: ${LEDGER_VERSION}"
echo ""

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
# Check for specs
# -----------------------------------------------------------------
if [[ ! -d "$SPEC_DIR" ]]; then
    log_error "Spec directory not found: ${SPEC_DIR}"
    echo ""
    echo "No specifications found to verify against."
    echo ""
    echo "To generate specifications:"
    echo ""
    echo "  1. Run full analysis first:"
    echo "     ./tools/ledger/run_full.sh"
    echo ""
    echo "  2. Then run verification:"
    echo "     ./tools/ledger/run_verify.sh"
    echo ""
    echo "This ensures you have a baseline specification to verify against."
    exit 1
fi

# Check if spec directory has content
SPEC_FILES=$(find "$SPEC_DIR" -type f \( -name "*.md" -o -name "*.json" -o -name "*.yaml" \) 2>/dev/null | wc -l | tr -d ' ')

if [[ "$SPEC_FILES" -eq 0 ]]; then
    log_warn "Spec directory exists but contains no specification files"
    echo ""
    echo "The spec directory exists but appears empty."
    echo ""
    echo "To regenerate specifications:"
    echo "  ./tools/ledger/run_full.sh"
    echo ""
    exit 1
fi

log_info "Found ${SPEC_FILES} specification files in ${SPEC_DIR}"
echo ""

# -----------------------------------------------------------------
# Run verification
# -----------------------------------------------------------------
log_info "Running verification against specs..."
log_info "  Spec dir: ${SPEC_DIR}"
log_info "  Repo: ${REPO_ROOT}"
echo ""

VERIFY_EXIT_CODE=0
cd "${REPO_ROOT}"
"$LEDGER_BIN" spec verify \
    --spec "artifacts/ledger/spec" \
    --repo "." || VERIFY_EXIT_CODE=$?

echo ""

if [[ $VERIFY_EXIT_CODE -eq 0 ]]; then
    log_success "Verification passed!"
    echo ""
    echo "The codebase conforms to the recorded specifications."
else
    log_error "Verification failed (exit code: ${VERIFY_EXIT_CODE})"
    echo ""
    echo "The codebase has diverged from the recorded specifications."
    echo ""
    echo "Options:"
    echo "  1. Fix the code to match specifications"
    echo "  2. Update specifications if changes are intentional:"
    echo "     ./tools/ledger/run_full.sh"
    echo ""
fi

exit $VERIFY_EXIT_CODE
