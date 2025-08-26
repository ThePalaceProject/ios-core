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

CHANGELOG=$(<"$CHANGELOG_PATH")

# Use bundler if available, otherwise fallback to global fastlane
if [ -f Gemfile ]; then
  echo "Installing bundle and invoking via bundle exec fastlane"
  bundle install
  bundle exec fastlane ios appstore changelog:"$CHANGELOG"
else
  fastlane ios appstore changelog:"$CHANGELOG"
fi
