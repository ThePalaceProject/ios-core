#!/bin/bash

# SUMMARY
#   Captures code coverage from simdrive E2E journeys and merges it with
#   unit test coverage to produce a combined report.
#
# PREREQUISITES
#   - Palace.app built with coverage instrumentation (the same build produced
#     by xcodebuild test -enableCodeCoverage YES)
#   - A booted simulator with the app installed
#   - simdrive MCP server available
#   - Unit test xcresult bundle (optional, for merging)
#
# USAGE
#   ./scripts/simdrive-coverage.sh [--sim-id UDID] [--xcresult PATH] [--output DIR]
#
# OUTPUT
#   combined-coverage.profdata   — merged profdata (unit + E2E)
#   combined-coverage.lcov       — LCOV report for CI tools
#   coverage-summary.json        — JSON summary with line/function percentages

set -euo pipefail

# Defaults
SIM_ID="${SIM_ID:-31CF5C43-DD55-4889-B3B2-9A6810B4E98F}"
XCRESULT_PATH=""
OUTPUT_DIR="./coverage-output"
APP_BUNDLE=""

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --sim-id) SIM_ID="$2"; shift 2;;
        --xcresult) XCRESULT_PATH="$2"; shift 2;;
        --output) OUTPUT_DIR="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

mkdir -p "$OUTPUT_DIR"

echo "=== simdrive Coverage Collection ==="
echo "Simulator: $SIM_ID"

# ---------------------------------------------------------------
# Step 1: Find the instrumented Palace binary
# ---------------------------------------------------------------
# The binary built with -enableCodeCoverage YES has LLVM instrumentation.
# Find it in DerivedData or the simulator's installed apps.

APP_CONTAINER=$(xcrun simctl get_app_container "$SIM_ID" org.thepalaceproject.palace 2>/dev/null || true)

if [ -z "$APP_CONTAINER" ]; then
    echo "Palace not installed on simulator $SIM_ID"
    echo "Install it first: xcrun simctl install $SIM_ID <path-to-Palace.app>"
    exit 1
fi

APP_BUNDLE="$APP_CONTAINER"
BINARY_PATH="$APP_BUNDLE/Palace"
echo "App binary: $BINARY_PATH"

if [ ! -f "$BINARY_PATH" ]; then
    echo "Binary not found at $BINARY_PATH"
    exit 1
fi

# Check if binary has coverage instrumentation
if ! nm "$BINARY_PATH" 2>/dev/null | grep -q "__llvm_prf"; then
    echo "WARNING: Binary does not appear to have LLVM coverage instrumentation."
    echo "Build with: xcodebuild build-for-testing -enableCodeCoverage YES"
    echo "Then install the instrumented .app into the simulator."
fi

# ---------------------------------------------------------------
# Step 2: Set LLVM_PROFILE_FILE env var in the simulator
# ---------------------------------------------------------------
# This tells the instrumented binary where to write .profraw files.
# Must be set BEFORE the app launches.

PROFRAW_DIR="/tmp/palace-coverage"
PROFRAW_PATTERN="$PROFRAW_DIR/palace-%p-%m.profraw"

echo "Setting LLVM_PROFILE_FILE in simulator..."
xcrun simctl spawn "$SIM_ID" mkdir -p "$PROFRAW_DIR"

# Set the env var for the app's bundle ID
# This persists across app launches until the simulator is erased
xcrun simctl spawn "$SIM_ID" defaults write org.thepalaceproject.palace \
    LLVM_PROFILE_FILE -string "$PROFRAW_PATTERN" 2>/dev/null || true

# Also set via launchctl (more reliable for env vars)
# The SIMCTL_CHILD_ prefix forwards env vars to child processes
export SIMCTL_CHILD_LLVM_PROFILE_FILE="$PROFRAW_PATTERN"

echo "Profraw will be written to: $PROFRAW_PATTERN"

# ---------------------------------------------------------------
# Step 3: Clear any previous profraw files
# ---------------------------------------------------------------
echo "Clearing previous profraw files..."
xcrun simctl spawn "$SIM_ID" rm -rf "$PROFRAW_DIR" 2>/dev/null || true
xcrun simctl spawn "$SIM_ID" mkdir -p "$PROFRAW_DIR"

# ---------------------------------------------------------------
# Step 4: Run simdrive journeys
# ---------------------------------------------------------------
# This is where simdrive drives the app. The MCP server handles
# app launch, so the LLVM_PROFILE_FILE env must be set before this.
#
# In CI, this step would invoke the simdrive MCP tool.
# Locally, you'd run your journeys manually or via a wrapper script.
#
# For now, we just print instructions and wait for manual execution.

echo ""
echo "=== Ready for simdrive journeys ==="
echo "The simulator is configured to collect coverage."
echo ""
echo "Run your simdrive journeys now. When done, press Enter to collect coverage."
echo "(In CI, this step would be automated via the simdrive MCP tools.)"
echo ""

if [ -t 0 ]; then
    # Interactive: wait for user
    read -r -p "Press Enter when journeys are complete..."
else
    # Non-interactive (CI): skip the wait, assume journeys already ran
    echo "Non-interactive mode: collecting coverage immediately."
fi

# ---------------------------------------------------------------
# Step 5: Force the app to flush coverage data and terminate
# ---------------------------------------------------------------
echo "Terminating app to flush profraw..."
xcrun simctl terminate "$SIM_ID" org.thepalaceproject.palace 2>/dev/null || true
sleep 2  # Give it a moment to write

# ---------------------------------------------------------------
# Step 6: Extract profraw files from the simulator
# ---------------------------------------------------------------
echo "Extracting profraw files..."

LOCAL_PROFRAW_DIR="$OUTPUT_DIR/profraw"
mkdir -p "$LOCAL_PROFRAW_DIR"

# Copy profraw files from simulator to host
PROFRAW_COUNT=0
for remote_file in $(xcrun simctl spawn "$SIM_ID" find "$PROFRAW_DIR" -name "*.profraw" 2>/dev/null); do
    local_file="$LOCAL_PROFRAW_DIR/$(basename "$remote_file")"
    xcrun simctl spawn "$SIM_ID" cat "$remote_file" > "$local_file"
    PROFRAW_COUNT=$((PROFRAW_COUNT + 1))
    echo "  Extracted: $(basename "$remote_file") ($(wc -c < "$local_file") bytes)"
done

if [ "$PROFRAW_COUNT" -eq 0 ]; then
    echo "No profraw files found. Possible causes:"
    echo "  1. Binary was not built with coverage instrumentation"
    echo "  2. LLVM_PROFILE_FILE was not set before app launch"
    echo "  3. App crashed before writing coverage data"
    echo "  4. simdrive didn't exercise any code paths"
    exit 1
fi

echo "Collected $PROFRAW_COUNT profraw file(s)"

# ---------------------------------------------------------------
# Step 7: Merge profraw into profdata
# ---------------------------------------------------------------
echo "Merging profraw files..."
SIMDRIVE_PROFDATA="$OUTPUT_DIR/simdrive-coverage.profdata"

xcrun llvm-profdata merge -sparse "$LOCAL_PROFRAW_DIR"/*.profraw \
    -o "$SIMDRIVE_PROFDATA"

echo "simdrive profdata: $SIMDRIVE_PROFDATA"

# ---------------------------------------------------------------
# Step 8: Optionally merge with unit test coverage
# ---------------------------------------------------------------
FINAL_PROFDATA="$SIMDRIVE_PROFDATA"

if [ -n "$XCRESULT_PATH" ] && [ -d "$XCRESULT_PATH" ]; then
    echo "Merging with unit test coverage from: $XCRESULT_PATH"

    # Extract profdata from xcresult
    UNIT_PROFDATA="$OUTPUT_DIR/unit-coverage.profdata"
    xcrun xccov view --report --json "$XCRESULT_PATH" > /dev/null 2>&1 || true

    # The xcresult contains profdata internally — extract it
    XCRESULT_PROFDATA=$(find "$XCRESULT_PATH" -name "*.profdata" 2>/dev/null | head -1)

    if [ -n "$XCRESULT_PROFDATA" ]; then
        echo "Found unit test profdata: $XCRESULT_PROFDATA"
        COMBINED_PROFDATA="$OUTPUT_DIR/combined-coverage.profdata"

        xcrun llvm-profdata merge -sparse \
            "$SIMDRIVE_PROFDATA" \
            "$XCRESULT_PROFDATA" \
            -o "$COMBINED_PROFDATA"

        FINAL_PROFDATA="$COMBINED_PROFDATA"
        echo "Combined profdata: $COMBINED_PROFDATA"
    else
        echo "Could not extract profdata from xcresult — using simdrive-only coverage"
    fi
fi

# ---------------------------------------------------------------
# Step 9: Generate reports
# ---------------------------------------------------------------
echo "Generating coverage reports..."

# LCOV format (for CI tools, Codecov, etc.)
LCOV_REPORT="$OUTPUT_DIR/combined-coverage.lcov"
xcrun llvm-cov export \
    -format=lcov \
    -instr-profile "$FINAL_PROFDATA" \
    "$BINARY_PATH" \
    > "$LCOV_REPORT" 2>/dev/null || true

# JSON summary
JSON_REPORT="$OUTPUT_DIR/coverage-summary.json"
xcrun llvm-cov export \
    -format=text \
    -instr-profile "$FINAL_PROFDATA" \
    -summary-only \
    "$BINARY_PATH" \
    > "$JSON_REPORT" 2>/dev/null || true

# Human-readable summary
echo ""
echo "=== Coverage Summary ==="
xcrun llvm-cov report \
    -instr-profile "$FINAL_PROFDATA" \
    "$BINARY_PATH" \
    2>/dev/null | tail -5 || echo "(could not generate summary)"

echo ""
echo "=== Output Files ==="
echo "  Profdata:  $FINAL_PROFDATA"
echo "  LCOV:      $LCOV_REPORT"
echo "  JSON:      $JSON_REPORT"
echo ""
echo "Done."
