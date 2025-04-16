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


# Ensure Python virtual environment is activated
if [ -d ".venv" ]; then
  source .venv/bin/activate
else
  echo "❌ Virtual environment not found! Installing dependencies..."
  python3 -m venv .venv
  source .venv/bin/activate
  python3 -m pip install --upgrade pip
  python3 -m pip install requests
fi

# Debugging: Ensure requests module is installed
python3 -m pip show requests || { echo "❌ 'requests' module not found!"; exit 1; }

# Set PYTHONPATH to ensure the venv is used correctly
export PYTHONPATH="$(pwd)/.venv/lib/python3.11/site-packages:$PYTHONPATH"

# Project version
source ./scripts/xcode-settings.sh

# Create release notes
echo "### Changelog:" > $RELEASE_NOTES_PATH
echo "" >> $RELEASE_NOTES_PATH
source .venv/bin/activate && ./scripts/release-notes.sh -v 2 --token "$GITHUB_TOKEN" >> $RELEASE_NOTES_PATH

# Create TestFlight changelog
source .venv/bin/activate && ./scripts/release-notes.sh -v 3 --token "$GITHUB_TOKEN" >> $CHANGELOG_PATH

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
