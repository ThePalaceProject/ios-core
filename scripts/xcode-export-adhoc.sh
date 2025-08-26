#!/bin/bash

# SUMMARY
#   Exports an archive for The Palace Project generating the related ipa.
#
# SYNOPSIS
#   xcode-export-adhoc.sh
#
# PARAMETERS
#   See xcode-settings.sh for possible parameters.
#
# USAGE
#   Run this script from the root of `ios-core` repo, e.g.:
#
#     ./scripts/xcode-export-adhoc.sh
#
# RESULTS
#   The generated .ipa is placed in its own directory inside
#   `./Build/Palace-<version>` folder.

source "$(dirname $0)/xcode-settings.sh"

echo "Exporting $ARCHIVE_NAME for Ad-Hoc distribution..."

# Use bundler if available, otherwise try global fastlane
if [ -f Gemfile ]; then
  echo "Installing bundle and invoking via bundle exec fastlane"
  bundle install --jobs 4 --retry 3 || gem install fastlane -N
  bundle exec fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR || fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR
else
  gem install fastlane -N || true
  fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR
fi

echo "Uploading archive:"

./scripts/ios-binaries-upload.sh
