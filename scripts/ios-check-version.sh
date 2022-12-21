#!/bin/bash

# SUMMARY
#   Checks if a binary with the current build number already exists on the
#   https://github.com/ThePalaceProject/ios-binaries repo.
#
# SYNOPSIS
#   ios-check-version.sh
#
# PARAMETERS
#   See xcode-settings.sh for possible parameters.
#
# USAGE
#   Run this script from the root of ios-core repo, e.g.:
#
#     ./scripts/ios-binaries-check

set -eo pipefail

source "$(dirname $0)/xcode-settings.sh"

CURL_RESULT=`curl -I -s -o /dev/null -w "%{http_code}"  https://github.com/ThePalaceProject/ios-binaries/blob/master/$UPLOAD_FILENAME`

if [ "$CURL_RESULT" == 200 ]; then
  echo "Build for ${ARCHIVE_NAME} already exists in ios-binaries"
  echo "version_changed=0" >> $GITHUB_OUTPUT
elif [ "$CURL_RESULT" != 404 ]; then
  echo "Obtained unexpected curl result for file named \"$UPLOAD_FILENAME\""
  exit 1
else
  echo "Build for ${ARCHIVE_NAME} doesn't exist in ios-binaries"    
  echo "version_changed=1" >> $GITHUB_OUTPUT
fi
