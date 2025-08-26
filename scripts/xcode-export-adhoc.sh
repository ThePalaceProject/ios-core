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

# Ensure Bundler 2 is used and gems are installed
if [ -f Gemfile ]; then
  echo "Installing bundle and invoking via bundle exec fastlane"
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler -v "~> 2.7" --no-document
  fi
  bundle _2.7.1_ install --path vendor/bundle
  bundle _2.7.1_ exec fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR
else
  fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR
fi

echo "Uploading archive:"

./scripts/ios-binaries-upload.sh
