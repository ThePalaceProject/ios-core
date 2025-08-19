#!/bin/bash

# SUMMARY
#   Runs the unit tests for Palace.
#
# SYNOPSIS
#   xcode-test.sh
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/xcode-test.sh

echo "Running unit tests for Palace..."
echo "💡 For faster tests, use: ./scripts/xcode-test-optimized.sh"

fastlane ios test