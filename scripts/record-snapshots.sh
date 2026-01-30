#!/bin/bash

# SUMMARY
#   Records all snapshot tests for Palace.
#   Run this script when you need to regenerate reference images.
#
# SYNOPSIS
#   ./scripts/record-snapshots.sh [--device DEVICE] [--test TEST_NAME]
#
# OPTIONS
#   --device DEVICE    Specific device to record on (default: all configured devices)
#   --test TEST_NAME   Specific test class to record (default: all snapshot tests)
#   --help             Show this help message
#
# EXAMPLES
#   ./scripts/record-snapshots.sh
#   ./scripts/record-snapshots.sh --device "iPhone SE (3rd generation)"
#   ./scripts/record-snapshots.sh --test FacetsSelectorSnapshotTests

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEVICE=""
TEST_FILTER=""

# Devices to record on (must match SnapshotDevice enum and CI availability)
DEVICES=(
  "iPhone SE (3rd generation)"
  "iPhone 14"
)

# All snapshot test classes
SNAPSHOT_TESTS=(
  "FacetsSelectorSnapshotTests"
  "CatalogSnapshotTests"
  "SettingsSnapshotTests"
  "BookDetailSnapshotTests"
  "HoldsSnapshotTests"
  "MyBooksSnapshotTests"
  "OnboardingSnapshotTests"
  "PDFViewsSnapshotTests"
  "ReservationsSnapshotTests"
  "SearchSnapshotTests"
  "AudiobookPlayerSnapshotTests"
)

show_help() {
  echo "Usage: ./scripts/record-snapshots.sh [OPTIONS]"
  echo ""
  echo "Records snapshot test reference images for Palace."
  echo ""
  echo "Options:"
  echo "  --device DEVICE    Record on specific device (default: all devices)"
  echo "  --test TEST_NAME   Record specific test class (default: all snapshot tests)"
  echo "  --list-devices     List available simulators"
  echo "  --list-tests       List snapshot test classes"
  echo "  --help             Show this help message"
  echo ""
  echo "Examples:"
  echo "  ./scripts/record-snapshots.sh"
  echo "  ./scripts/record-snapshots.sh --device 'iPhone SE (3rd generation)'"
  echo "  ./scripts/record-snapshots.sh --test FacetsSelectorSnapshotTests"
}

list_devices() {
  echo -e "${BLUE}Available iPhone simulators:${NC}"
  xcrun simctl list devices available | grep iPhone
}

list_tests() {
  echo -e "${BLUE}Snapshot test classes:${NC}"
  for test in "${SNAPSHOT_TESTS[@]}"; do
    echo "  - $test"
  done
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --device)
      DEVICE="$2"
      shift 2
      ;;
    --test)
      TEST_FILTER="$2"
      shift 2
      ;;
    --list-devices)
      list_devices
      exit 0
      ;;
    --list-tests)
      list_tests
      exit 0
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      show_help
      exit 1
      ;;
  esac
done

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Palace Snapshot Recording Script     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# Determine devices to use
if [ -n "$DEVICE" ]; then
  DEVICES_TO_USE=("$DEVICE")
else
  DEVICES_TO_USE=("${DEVICES[@]}")
fi

# Determine tests to run
if [ -n "$TEST_FILTER" ]; then
  TESTS_TO_RUN=("$TEST_FILTER")
else
  TESTS_TO_RUN=("${SNAPSHOT_TESTS[@]}")
fi

echo -e "${YELLOW}Recording snapshots for:${NC}"
echo -e "  Devices: ${DEVICES_TO_USE[*]}"
echo -e "  Tests: ${TESTS_TO_RUN[*]}"
echo ""

# Build test filter arguments
TEST_ARGS=""
for test in "${TESTS_TO_RUN[@]}"; do
  TEST_ARGS="$TEST_ARGS -only-testing:PalaceTests/$test"
done

# Record on each device
for device in "${DEVICES_TO_USE[@]}"; do
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}Recording on: $device${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  
  # Check if device is available
  if ! xcrun simctl list devices available | grep -q "$device"; then
    echo -e "${YELLOW}⚠️  Device '$device' not available, skipping...${NC}"
    continue
  fi
  
  # Run tests with RECORD_SNAPSHOTS environment variable
  RECORD_SNAPSHOTS=1 xcodebuild test \
    -project Palace.xcodeproj \
    -scheme Palace \
    -destination "platform=iOS Simulator,name=$device" \
    -configuration Debug \
    $TEST_ARGS \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    2>&1 | xcpretty || {
      echo -e "${YELLOW}⚠️  Some tests may have failed on $device (expected during recording)${NC}"
    }
  
  echo ""
done

echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Snapshot Recording Complete      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "Snapshots saved to: ${BLUE}PalaceTests/Snapshots/__Snapshots__/${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review the generated snapshots"
echo "  2. git add PalaceTests/Snapshots/__Snapshots__/"
echo "  3. git commit -m 'Update snapshot reference images'"
echo ""
