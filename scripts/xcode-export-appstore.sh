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

# Ensure Bundler 2 is used and gems are installed
if [ -f Gemfile ]; then
  echo "Installing bundle and invoking via bundle exec fastlane"
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler -v "~> 2.7" --no-document
  fi
  bundle _2.7.1_ install --path vendor/bundle
  bundle _2.7.1_ exec fastlane ios appstore changelog:"$CHANGELOG"
else
  fastlane ios appstore changelog:"$CHANGELOG"
fi
