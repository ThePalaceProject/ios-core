#!/bin/bash

# SUMMARY
#   Runs optimized unit tests for Palace with performance improvements.
#
# SYNOPSIS
#   xcode-test-optimized.sh
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/xcode-test-optimized.sh

set -euo pipefail

echo "Running optimized unit tests for Palace..."

# Skip the separate build step - xcodebuild test builds automatically and more efficiently
# Use parallel testing and optimized flags

# Use direct xcodebuild for faster execution (skip Fastlane overhead)
# Use the placeholder ID for generic iOS Simulator compatibility
echo "Running optimized tests with generic iOS Simulator placeholder..."

xcodebuild test \
    -project Palace.xcodeproj \
    -scheme Palace \
    -destination 'platform=iOS Simulator,id=dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder' \
    -configuration Debug \
    -enableCodeCoverage NO \
    -parallel-testing-enabled YES \
    -maximum-parallel-testing-workers 4 \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    GCC_OPTIMIZATION_LEVEL=0 \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    ENABLE_TESTABILITY=YES

echo "✅ Unit tests completed successfully!"
