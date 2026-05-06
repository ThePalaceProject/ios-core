#!/bin/bash
# Full performance profiling suite for Palace iOS
# Runs Allocations, Leaks, and Time Profiler traces on physical device
# while the Appium walker drives the app through all major flows.
#
# Usage: ./scripts/run-perf-suite.sh [--version 2.2.5]

set -e

VERSION="${1:-2.2.5}"
DEVICE_ECID="00008150-00142D540A87801C"
DEVICE_UDID="31471BBD-6889-5DAC-9497-BCD565AB1CD6"
WDA_URL="http://192.168.1.26:8100"
BUNDLE_ID="org.thepalaceproject.palace"
PROFILING_DIR="$HOME/Desktop/regression-PP-4020/profiling"
WALKER="scripts/perf-walker-device.py"

mkdir -p "$PROFILING_DIR"

echo "==================================================================="
echo "  Palace Performance Profiling Suite — v${VERSION}"
echo "  Device: Moes Max (iPhone 17 Pro Max)"
echo "  Output: $PROFILING_DIR"
echo "==================================================================="

# Ensure Palace is running
echo ""
echo ">>> Launching Palace on device..."
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" 2>&1 | tail -1
sleep 3

get_pid() {
    xcrun devicectl device info processes --device "$DEVICE_UDID" 2>&1 | grep -i palace | awk '{print $1}'
}

# Check WDA
echo ">>> Checking WDA..."
WDA_READY=$(curl -s "$WDA_URL/status" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',{}).get('ready',False))" 2>/dev/null || echo "False")
if [ "$WDA_READY" != "True" ]; then
    echo "ERROR: WDA not running at $WDA_URL"
    echo "Start it with: xcodebuild test-without-building -project ~/.specterqa/wda/WebDriverAgent/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination id=$DEVICE_ECID -derivedDataPath ~/.specterqa/wda/build-device"
    exit 1
fi
echo "WDA is ready."

run_trace() {
    local TEMPLATE="$1"
    local TRACE_NAME="$2"
    local TIME_LIMIT="${3:-8m}"
    local TRACE_PATH="$PROFILING_DIR/${TRACE_NAME}-${VERSION}.trace"

    echo ""
    echo "==================================================================="
    echo "  TRACE: $TEMPLATE ($TRACE_NAME) — ${TIME_LIMIT} limit"
    echo "==================================================================="

    # Clean old trace
    rm -rf "$TRACE_PATH"

    # Get fresh PID (Appium session may have restarted the app)
    local PID=$(get_pid)
    if [ -z "$PID" ]; then
        echo "Palace not running — relaunching..."
        xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" 2>&1 | tail -1
        sleep 3
        PID=$(get_pid)
    fi
    echo "Palace PID: $PID"

    # Start the walker first (creates WDA session, activates app)
    # But we need xctrace attached BEFORE the walker runs phases.
    # Solution: start xctrace attached to the app by name, not PID.
    # xctrace --attach accepts process name.

    xctrace record \
        --device "$DEVICE_ECID" \
        --template "$TEMPLATE" \
        --attach "$PID" \
        --output "$TRACE_PATH" \
        --time-limit "$TIME_LIMIT" \
        --no-prompt &
    local XCTRACE_PID=$!
    echo "xctrace started (PID: $XCTRACE_PID)"
    sleep 3

    # Run walker
    echo "Running performance walker..."
    python3 "$WALKER" \
        --wda-url "$WDA_URL" \
        --device-ecid "$DEVICE_ECID" \
        --app-pid "$PID" \
        --output-dir "$PROFILING_DIR/${TRACE_NAME}-screenshots" \
        2>&1 || true

    # Wait for xctrace to finish
    echo "Waiting for xctrace to complete..."
    wait $XCTRACE_PID 2>/dev/null || true

    local TRACE_SIZE=$(du -sh "$TRACE_PATH" 2>/dev/null | awk '{print $1}')
    echo "Trace saved: $TRACE_PATH ($TRACE_SIZE)"
}

# ============================================================
# Run all three traces
# ============================================================

echo ""
echo ">>> Starting profiling suite for Palace ${VERSION}..."
echo ""

# 1. Allocations (heap allocations, malloc/free tracking)
run_trace "Allocations" "allocations" "8m"

# Brief pause between traces
sleep 5

# Relaunch Palace for clean state
echo ""
echo ">>> Relaunching Palace for Leaks trace..."
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" 2>&1 | tail -1
sleep 5

# 2. Leaks (memory leak detection)
run_trace "Leaks" "leaks" "8m"

# Brief pause
sleep 5

# Relaunch for clean state
echo ""
echo ">>> Relaunching Palace for Time Profiler trace..."
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" 2>&1 | tail -1
sleep 5

# 3. Time Profiler (CPU usage, hot functions)
run_trace "Time Profiler" "time-profiler" "5m"

echo ""
echo "==================================================================="
echo "  PROFILING COMPLETE — Palace ${VERSION}"
echo "==================================================================="
echo ""
echo "Traces saved to: $PROFILING_DIR/"
ls -lh "$PROFILING_DIR/"*.trace 2>/dev/null
echo ""
echo "Open in Instruments.app:"
echo "  open $PROFILING_DIR/allocations-${VERSION}.trace"
echo "  open $PROFILING_DIR/leaks-${VERSION}.trace"
echo "  open $PROFILING_DIR/time-profiler-${VERSION}.trace"
