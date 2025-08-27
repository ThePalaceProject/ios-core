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

# Use bundler with cached gems from setup-ruby action
bundle exec fastlane ios beta output_name:$ARCHIVE_NAME.ipa export_path:$ARCHIVE_DIR

echo "Uploading archive:"

./scripts/ios-binaries-upload.sh
