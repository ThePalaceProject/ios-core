#!/bin/bash

# SUMMARY
#   Runs the unit tests for Palace.
#
# SYNOPSIS
#   xcode-test.sh
#
# PARAMETERS
#   See xcode-settings.sh for possible parameters.
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/xcode-test.sh

source "$(dirname $0)/xcode-settings.sh"

echo "Running unit tests for Palace..."

xcodebuild -project "$PROJECT_NAME" \
           -scheme "$SCHEME" \
           -destination platform=iOS\ Simulator,OS=14.4,name=iPhone\ 12\ Pro\
           clean test | \
           if command -v xcpretty &> /dev/null; then xcpretty; else cat; fi
