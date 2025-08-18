#!/bin/bash

# SUMMARY
#   Runs essential Palace unit tests quickly for rapid feedback during development.
#
# SYNOPSIS
#   test-quick.sh
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/test-quick.sh

set -euo pipefail

echo "🚀 Running quick essential tests for Palace..."

# Run only the most important test classes for rapid feedback
xcodebuild test \
    -project Palace.xcodeproj \
    -scheme Palace \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    -enableCodeCoverage NO \
    -parallel-testing-enabled YES \
    -maximum-parallel-testing-workers 4 \
    -only-testing:PalaceTests/TPPBookTests \
    -only-testing:PalaceTests/AccountTests \
    -only-testing:PalaceTests/OPDSTests \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    GCC_OPTIMIZATION_LEVEL=0 \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    ENABLE_TESTABILITY=YES

echo "✅ Quick tests completed successfully!"
echo "💡 To run all tests: ./scripts/xcode-test.sh"
echo "💡 To run optimized tests: ./scripts/xcode-test-optimized.sh"
