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

# Use bundler if available, otherwise try global fastlane
if [ -f Gemfile ]; then
  echo "Installing bundle and invoking via bundle exec fastlane"
  gem install bundler -v "~> 2.0" --no-document || true
  bundle install --jobs 4 --retry 3 || gem install fastlane -N
  bundle exec fastlane ios appstore changelog:"$CHANGELOG" || fastlane ios appstore changelog:"$CHANGELOG"
else
  gem install fastlane -N || true
  fastlane ios appstore changelog:"$CHANGELOG"
fi
