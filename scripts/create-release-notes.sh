#!/bin/bash

# SUMMARY
#   Creates release notes file, 
#   saves project vresion in GITHUB_ENV for further steps.
#
# USAGE
#
#     ./scripts/create-release-notes.sh

RELEASE_NOTES_PATH="./fastlane/release-notes.md"

# Project version
source ./scripts/xcode-settings.sh

# Create release notes
echo "### Changelog:" > $RELEASE_NOTES_PATH
echo "" >> $RELEASE_NOTES_PATH
./scripts/release-notes.sh -v 2 >> $RELEASE_NOTES_PATH

if [ "$BUILD_CONTEXT" == "ci" ]; then
  # Save variables for further steps
  echo "RELEASE_NOTES_PATH=$RELEASE_NOTES_PATH" >> $GITHUB_ENV
  echo "VERSION_NUM=$VERSION_NUM" >> $GITHUB_ENV
else
  echo "Release notes path: " $RELEASE_NOTES_PATH
  echo "Version: " $VERSION_NUM
fi
