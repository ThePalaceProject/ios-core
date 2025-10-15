#!/bin/bash

# SUMMARY
#   Uploads an exported .ipa for The Palace Project to the
#   https://github.com/ThePalaceProject/ios-binaries repo.
#
# SYNOPSIS
#   ios-binaries-upload.sh
#
# USAGE
#   Run this script from the root of ios-core repo, e.g.:
#
#     ./scripts/ios-binaries-upload

source "$(dirname $0)/xcode-settings.sh"

echo "Uploading $ARCHIVE_NAME to 'ios-binaries' repo..."

PALACE_DIR=$PWD

# In a GitHub Actions CI context we can't clone a repo as a sibling
if [ "$BUILD_CONTEXT" != "ci" ]; then
  cd ..
fi

if [[ -d "ios-binaries" ]]; then
  echo "ios-binaries repo appears to be cloned already..."
elif [ "$BUILD_CONTEXT" != "ci" ]; then
# see upload*.yml GitHub actions; ios-binaries is cloned with the rest repos
  git clone git@github.com:ThePalaceProject/ios-binaries.git
fi

IOS_BINARIES_DIR_NAME=ios-binaries
IOS_BINARIES_DIR_PATH="$PWD/$IOS_BINARIES_DIR_NAME"

 # check we didn't already upload this build
ZIP_FULLPATH="$IOS_BINARIES_DIR_PATH/$UPLOAD_FILENAME"
if [[ -f "$ZIP_FULLPATH" ]]; then
  echo "${ARCHIVE_NAME} already exists on iOS-binaries"
  exit 1
fi

# zip .ipa with dSYMs
cd $PALACE_DIR
cd "$ARCHIVE_DIR"
echo "Creating $ZIP_FULLPATH"
zip -r "$ZIP_FULLPATH" .

# upload to iOS-binaries repo
cd "$IOS_BINARIES_DIR_PATH"

# Ensure git identity in CI
if [ "$BUILD_CONTEXT" = "ci" ]; then
  git config user.email "ci@thepalaceproject.org" || true
  git config user.name "Palace CI" || true
fi

git add "$ZIP_FULLPATH"
git status

COMMIT_MSG="Add ${ARCHIVE_NAME} build"
git commit -m "$COMMIT_MSG"
echo "Committed."
git push -f
