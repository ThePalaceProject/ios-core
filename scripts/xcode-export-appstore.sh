#!/bin/bash

# SUMMARY
#   Exports The Palace Projects archive for App Store distribution
#   generating the related ipa.
#
# SYNOPSIS
#   xcode-export-appstore.sh
#
# USAGE
#   Run this script from the root of `ios-core` repo, e.g.:
#
#     ./scripts/xcode-export-appstore.sh
#
# RESULTS
#   The generated .ipa is uploaded to TestFlight.

source "$(dirname $0)/xcode-settings.sh"

CHANGELOG=$(<"$CHANGELOG_PATH")
fastlane ios appstore changelog:"$CHANGELOG"

echo "gym logs:"
echo ">>>"
cat /Users/runner/Library/Logs/gym/Palace-Palace.log
echo ">>>"
