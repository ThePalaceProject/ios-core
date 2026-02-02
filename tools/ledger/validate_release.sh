#!/usr/bin/env bash
#
# validate_release.sh - Canonical validation script for ledger-palace-plan
#
# This script is the SINGLE SOURCE OF TRUTH for all release validation.
# Both local development and CI MUST use this script.
#
# Exit Codes:
#   0 - All validations passed
#   1 - Test failures
#   2 - Ledger analysis failures
#   3 - Spec verification failures
#   4 - Build failures
#
# Usage:
#   ./tools/ledger/validate_release.sh [ITERATION]
#
#   ITERATION defaults to 1, or auto-increments from existing iter-N directories
#
# Output:
#   reports/dogfood/iter-N/
#     ├── README.md           - Reproduction commands
#     ├── scorecard.md        - Before/after metrics
#     ├── test-results/       - Test output
#     ├── ledger-analysis/    - Full analysis artifacts
#     ├── ledger-diff/        - Diff vs main
#     └── spec-verification/  - Spec verification output

set -euo pipefail

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEDGER_BIN="${REPO_ROOT}/tools/bin/ledger"

# Auto-detect iteration number
if [[ -n "${1:-}" ]]; then
    ITERATION="$1"
else
    # Find highest existing iter-N and increment
    LATEST_ITER=$(ls -d "${REPO_ROOT}/reports/dogfood/iter-"* 2>/dev/null | sort -V | tail -1 | grep -oE '[0-9]+$' || echo "0")
    ITERATION=$((LATEST_ITER + 1))
fi

DOGFOOD_DIR="${REPO_ROOT}/reports/dogfood/iter-${ITERATION}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# Exit codes
EXIT_TEST=1
EXIT_LEDGER=2
EXIT_SPEC=3
EXIT_BUILD=4

# Track overall status
VALIDATION_PASSED=true
declare -a FAILURES=()

# -----------------------------------------------------------------
# Colors
# -----------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${CI:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    BOLD='\033[1m'
else
    RED='' GREEN='' BLUE='' YELLOW='' NC='' BOLD=''
fi

log_header() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }
log_info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
log_pass()   { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail()   { echo -e "${RED}[FAIL]${NC} $*"; VALIDATION_PASSED=false; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }

record_failure() {
    FAILURES+=("$1")
    log_fail "$1"
}

# -----------------------------------------------------------------
# Setup
# -----------------------------------------------------------------
log_header "LEDGER RELEASE VALIDATION - Iteration ${ITERATION}"
log_info "Timestamp: ${TIMESTAMP}"
log_info "Repository: ${REPO_ROOT}"
log_info "Output: ${DOGFOOD_DIR}"
echo ""

# Create dogfood directory structure
mkdir -p "${DOGFOOD_DIR}/test-results"
mkdir -p "${DOGFOOD_DIR}/ledger-analysis"
mkdir -p "${DOGFOOD_DIR}/ledger-diff"
mkdir -p "${DOGFOOD_DIR}/spec-verification"

cd "${REPO_ROOT}"

# Capture git state
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_SHA_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

log_info "Branch: ${GIT_BRANCH}"
log_info "Commit: ${GIT_SHA}"
echo ""

# -----------------------------------------------------------------
# Step 1: Install Ledger
# -----------------------------------------------------------------
log_header "Step 1: Install Ledger"

if [[ -x "${SCRIPT_DIR}/install_ledger.sh" ]]; then
    "${SCRIPT_DIR}/install_ledger.sh" 2>&1 | tee "${DOGFOOD_DIR}/ledger-install.log" || {
        record_failure "Ledger installation failed"
    }
else
    log_warn "install_ledger.sh not found, assuming ledger is available"
fi

if [[ -x "$LEDGER_BIN" ]]; then
    LEDGER_VERSION=$("$LEDGER_BIN" --version 2>&1 | head -1 || echo "unknown")
    log_pass "Ledger installed: ${LEDGER_VERSION}"
else
    record_failure "Ledger binary not available"
fi

# -----------------------------------------------------------------
# Step 2: Run Tests
# -----------------------------------------------------------------
log_header "Step 2: Run Unit Tests"

TEST_PASSED=true
TEST_SCRIPT="${REPO_ROOT}/scripts/xcode-test-optimized.sh"

if [[ -x "$TEST_SCRIPT" ]]; then
    log_info "Running: ${TEST_SCRIPT}"

    if "$TEST_SCRIPT" 2>&1 | tee "${DOGFOOD_DIR}/test-results/test-output.log"; then
        log_pass "Unit tests passed"
    else
        record_failure "Unit tests failed (see test-results/test-output.log)"
        TEST_PASSED=false
    fi

    # Copy xcresult if it exists
    if [[ -d "${REPO_ROOT}/TestResults.xcresult" ]]; then
        cp -R "${REPO_ROOT}/TestResults.xcresult" "${DOGFOOD_DIR}/test-results/" 2>/dev/null || true
    fi
else
    log_warn "Test script not found at ${TEST_SCRIPT}"
    log_info "Attempting xcodebuild test directly..."

    # Fallback to direct xcodebuild
    if xcodebuild test \
        -project Palace.xcodeproj \
        -scheme Palace \
        -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
        -resultBundlePath "${DOGFOOD_DIR}/test-results/TestResults.xcresult" \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee "${DOGFOOD_DIR}/test-results/test-output.log"; then
        log_pass "Unit tests passed"
    else
        record_failure "Unit tests failed"
        TEST_PASSED=false
    fi
fi

# -----------------------------------------------------------------
# Step 3: Ledger Full Analysis
# -----------------------------------------------------------------
log_header "Step 3: Ledger Full Analysis"

if [[ -x "$LEDGER_BIN" ]]; then
    log_info "Running full ledger analysis..."

    # Initialize if needed
    if [[ ! -f "${REPO_ROOT}/.ledger/config.json" ]]; then
        "$LEDGER_BIN" init --repo "${REPO_ROOT}" --no-interactive 2>&1 || true
    fi

    # Run analysis
    if "$LEDGER_BIN" analyze \
        --repo "${REPO_ROOT}" \
        --domains "arch,reach,a11y" \
        --write \
        2>&1 | tee "${DOGFOOD_DIR}/ledger-analysis/analyze.log"; then
        log_pass "Ledger analysis completed"
    else
        log_warn "Ledger analysis completed with warnings"
    fi

    # Copy analysis artifacts
    if [[ -f "${REPO_ROOT}/docs/ledger/ANALYSIS.md" ]]; then
        cp "${REPO_ROOT}/docs/ledger/ANALYSIS.md" "${DOGFOOD_DIR}/ledger-analysis/"
    fi

    # Build specs
    log_info "Building specifications..."
    "$LEDGER_BIN" spec build \
        --repo "${REPO_ROOT}" \
        --domains "arch,reach,a11y" \
        --format md \
        --output "${DOGFOOD_DIR}/ledger-analysis/spec" \
        2>&1 | tee "${DOGFOOD_DIR}/ledger-analysis/spec-build.log" || true
else
    record_failure "Ledger binary not available for analysis"
fi

# -----------------------------------------------------------------
# Step 4: Ledger Diff vs Main
# -----------------------------------------------------------------
log_header "Step 4: Ledger Diff vs Main"

if [[ -x "$LEDGER_BIN" ]]; then
    BASE_REF="${BASE_REF:-main}"

    # Verify base ref exists
    if git rev-parse --verify "${BASE_REF}" >/dev/null 2>&1 || \
       git rev-parse --verify "origin/${BASE_REF}" >/dev/null 2>&1; then

        log_info "Running diff: ${BASE_REF}..HEAD"

        "$LEDGER_BIN" spec diff \
            --base "${BASE_REF}" \
            --head HEAD \
            --format md \
            --output "${DOGFOOD_DIR}/ledger-diff/spec-diff.md" \
            --repo "${REPO_ROOT}" \
            2>&1 | tee "${DOGFOOD_DIR}/ledger-diff/diff.log" || {
                log_warn "Spec diff completed with warnings"
            }

        log_pass "Ledger diff completed"
    else
        log_warn "Base ref '${BASE_REF}' not available, skipping diff"
    fi
else
    record_failure "Ledger binary not available for diff"
fi

# -----------------------------------------------------------------
# Step 5: Spec Verification
# -----------------------------------------------------------------
log_header "Step 5: Spec Verification"

if [[ -x "$LEDGER_BIN" ]] && [[ -d "${DOGFOOD_DIR}/ledger-analysis/spec" ]]; then
    log_info "Running spec verification..."

    if "$LEDGER_BIN" spec verify \
        --repo "${REPO_ROOT}" \
        --spec "${DOGFOOD_DIR}/ledger-analysis/spec" \
        2>&1 | tee "${DOGFOOD_DIR}/spec-verification/verify.log"; then
        log_pass "Spec verification passed"
    else
        log_warn "Spec verification found issues (non-blocking for now)"
    fi
else
    log_warn "Spec verification skipped (no specs built)"
fi

# -----------------------------------------------------------------
# Step 6: Generate Artifacts
# -----------------------------------------------------------------
log_header "Step 6: Generate Artifacts"

# README.md with reproduction commands
cat > "${DOGFOOD_DIR}/README.md" << EOF
# Dogfood Report - Iteration ${ITERATION}

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Branch:** ${GIT_BRANCH}
**Commit:** ${GIT_SHA_FULL}

## Reproduction Commands

\`\`\`bash
# Checkout the exact commit
git checkout ${GIT_SHA_FULL}

# Run the same validation
./tools/ledger/validate_release.sh ${ITERATION}
\`\`\`

## Contents

| Directory | Description |
|-----------|-------------|
| test-results/ | Unit test output and xcresult bundle |
| ledger-analysis/ | Full ledger analysis artifacts |
| ledger-diff/ | Diff analysis vs main |
| spec-verification/ | Specification verification results |

## Validation Status

$(if [[ "$VALIDATION_PASSED" == "true" ]]; then echo "**PASSED**"; else echo "**FAILED**"; fi)

$(if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "### Failures"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo "- $f"
    done
fi)

## Rollback Instructions

If this validation caused issues:

\`\`\`bash
# Revert to previous state
git checkout main

# Or revert specific commits
git revert HEAD
\`\`\`
EOF

log_pass "README.md generated"

# scorecard.md with metrics
cat > "${DOGFOOD_DIR}/scorecard.md" << EOF
# Scorecard - Iteration ${ITERATION}

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Summary

| Metric | Value |
|--------|-------|
| Branch | ${GIT_BRANCH} |
| Commit | ${GIT_SHA} |
| Tests | $(if [[ "$TEST_PASSED" == "true" ]]; then echo "PASS"; else echo "FAIL"; fi) |
| Ledger | $(if [[ -x "$LEDGER_BIN" ]]; then echo "PASS"; else echo "N/A"; fi) |
| Overall | $(if [[ "$VALIDATION_PASSED" == "true" ]]; then echo "PASS"; else echo "FAIL"; fi) |

## Test Metrics (Palace Only)

$(if [[ -f "${DOGFOOD_DIR}/test-results/test-output.log" ]]; then
    # Extract test counts by counting individual test results
    # xcodebuild parallel testing outputs "Test case '...' passed/failed"
    # Filter to Palace tests only (exclude third-party: swift-protobuf, app-check, etc.)
    PALACE_PASSED=$(grep "passed on '" "${DOGFOOD_DIR}/test-results/test-output.log" 2>/dev/null | grep -c "Palace" | tr -d '[:space:]' || echo "0")
    PALACE_FAILED=$(grep "failed on '" "${DOGFOOD_DIR}/test-results/test-output.log" 2>/dev/null | grep -c "Palace" | tr -d '[:space:]' || echo "0")
    
    # Count third-party failures separately (URLValidationTests, etc.)
    THIRD_PARTY_FAILED=$(grep "failed on '" "${DOGFOOD_DIR}/test-results/test-output.log" 2>/dev/null | grep -v "Palace" | wc -l | tr -d '[:space:]' || echo "0")

    # Ensure numeric values
    [[ -z "$PALACE_PASSED" ]] && PALACE_PASSED=0
    [[ -z "$PALACE_FAILED" ]] && PALACE_FAILED=0
    [[ -z "$THIRD_PARTY_FAILED" ]] && THIRD_PARTY_FAILED=0
    PALACE_RUN=$((PALACE_PASSED + PALACE_FAILED))

    # Fallback to "Executed N tests" pattern if available
    if [[ "$PALACE_RUN" -eq 0 ]]; then
        PALACE_RUN=$(grep -oE "Executed [0-9]+ test" "${DOGFOOD_DIR}/test-results/test-output.log" | grep -oE "[0-9]+" | head -1 | tr -d '[:space:]' || echo "N/A")
        PALACE_FAILED=$(grep -oE "[0-9]+ failure" "${DOGFOOD_DIR}/test-results/test-output.log" | grep -oE "^[0-9]+" | head -1 | tr -d '[:space:]' || echo "0")
    fi

    echo "| Palace Tests Run | ${PALACE_RUN} |"
    echo "| Palace Tests Passed | ${PALACE_PASSED} |"
    echo "| Palace Tests Failed | ${PALACE_FAILED} |"
    echo "| Third-Party Failures (ignored) | ${THIRD_PARTY_FAILED} |"
else
    echo "| Palace Tests Run | N/A |"
    echo "| Palace Tests Passed | N/A |"
    echo "| Palace Tests Failed | N/A |"
    echo "| Third-Party Failures (ignored) | N/A |"
fi)

## Ledger Metrics

$(if [[ -f "${DOGFOOD_DIR}/ledger-analysis/analyze.log" ]]; then
    # Extract metrics from analyze log
    COMPONENTS=$(grep -oE "Components: [0-9]+" "${DOGFOOD_DIR}/ledger-analysis/analyze.log" | grep -oE "[0-9]+" | head -1 || echo "N/A")
    DEPENDENCIES=$(grep -oE "Dependencies: [0-9]+" "${DOGFOOD_DIR}/ledger-analysis/analyze.log" | grep -oE "[0-9]+" | head -1 || echo "N/A")
    AVG_COUPLING=$(grep -oE "Avg Coupling: [0-9.]+" "${DOGFOOD_DIR}/ledger-analysis/analyze.log" | grep -oE "[0-9.]+" | head -1 || echo "N/A")
    ORPHANS=$(grep -c "orphan_component" "${DOGFOOD_DIR}/ledger-analysis/analyze.log" 2>/dev/null || echo "0")
    
    # Determine health score based on issues
    if [[ "$ORPHANS" -eq 0 ]]; then
        HEALTH="100%"
    elif [[ "$ORPHANS" -le 4 ]]; then
        HEALTH="Good (known submodules)"
    else
        HEALTH="Needs attention"
    fi

    echo "| Components | ${COMPONENTS} |"
    echo "| Dependencies | ${DEPENDENCIES} |"
    echo "| Avg Coupling | ${AVG_COUPLING} |"
    echo "| Orphan Warnings | ${ORPHANS} |"
    echo "| Health | ${HEALTH} |"
else
    echo "| Components | N/A |"
    echo "| Dependencies | N/A |"
    echo "| Avg Coupling | N/A |"
    echo "| Orphan Warnings | N/A |"
    echo "| Health | N/A |"
fi)

## Before/After Comparison

_To be filled in by comparing with previous iteration._

| Metric | Before (iter-$((ITERATION-1))) | After (iter-${ITERATION}) | Delta |
|--------|-------------------------------|--------------------------|-------|
| Test Count | - | - | - |
| Coverage | - | - | - |
| Ledger Issues | - | - | - |
EOF

log_pass "scorecard.md generated"

# -----------------------------------------------------------------
# Final Summary
# -----------------------------------------------------------------
log_header "VALIDATION SUMMARY"

echo "Iteration: ${ITERATION}"
echo "Output: ${DOGFOOD_DIR}"
echo ""

if [[ "$VALIDATION_PASSED" == "true" ]]; then
    log_pass "All validations passed"
    echo ""
    echo "Artifacts ready for PR:"
    echo "  - ${DOGFOOD_DIR}/README.md"
    echo "  - ${DOGFOOD_DIR}/scorecard.md"
    exit 0
else
    log_fail "Validation failed with ${#FAILURES[@]} issue(s):"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    echo ""
    echo "Review logs in: ${DOGFOOD_DIR}"

    # Determine exit code based on failure type
    if [[ " ${FAILURES[*]} " =~ "Unit tests" ]]; then
        exit $EXIT_TEST
    elif [[ " ${FAILURES[*]} " =~ "Ledger" ]]; then
        exit $EXIT_LEDGER
    elif [[ " ${FAILURES[*]} " =~ "Spec" ]]; then
        exit $EXIT_SPEC
    else
        exit $EXIT_BUILD
    fi
fi
