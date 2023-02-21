#!/bin/bash

# SUMMARY
#   Creates release notes file, 
#   saves project vresion in GITHUB_ENV for further steps.
#
# USAGE
#
#     ./scripts/create-release-notes.sh

# Release notes for Github release
RELEASE_NOTES_PATH="./fastlane/release-notes.md"
# Changelog for TestFlight changelog
CHANGELOG_PATH="./fastlane/changelog.txt"

# Project version
source ./scripts/xcode-settings.sh

# Create release notes
echo "### Changelog:" > $RELEASE_NOTES_PATH
echo "" >> $RELEASE_NOTES_PATH
./scripts/release-notes.sh -v 2 --token "$GITHUB_TOKEN" >> $RELEASE_NOTES_PATH

# Create TestFlight changelog
./scripts/release-notes.sh -v 3 --token "$GITHUB_TOKEN" >> $CHANGELOG_PATH

if [ "$BUILD_CONTEXT" == "ci" ]; then
  # Save variables for further steps
  echo "RELEASE_NOTES_PATH=$RELEASE_NOTES_PATH" >> $GITHUB_ENV
  echo "CHANGELOG_PATH=$CHANGELOG_PATH" >> $GITHUB_ENV
  echo "VERSION_NUM=$VERSION_NUM" >> $GITHUB_ENV
else
  echo "Release notes path: " $RELEASE_NOTES_PATH
  echo "Changelog path: " $CHANGELOG_PATH
  echo "Version: " $VERSION_NUM
fi
