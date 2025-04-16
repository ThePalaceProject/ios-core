#/bin/bash

# SUMMARY
#   Collects release notes for GitHub and TestFlight versions
#   from pulls on `develop` branch if
#   https://github.com/ThePalaceProject/ios-core repo.
#
# SYNOPSIS
#   release-notes.sh
#
# USAGE
#   Run this script from the root of ios-core repo, e.g.:
#
#   ./scripts/release-notes.sh [-t TAG] [-v INFO_LEVEL] [-h]
#
#  Where:
#  -t TAG - tag to start collecting release notes from.
#  -v INFO_LEVEL - how much information to show:
#    1 (default) - pull request titles only;
#    2 - titles + links to PRs and  Notion tickets;
#    3 - titles + links to PRs and  Notion tickets + PR body text.
#  -h - show help
# 
#  Being started without parameters, the script shows PR titles to the most receent release.
#

if [ "$BUILD_CONTEXT" == "ci" ]; then
  CERTIFICATES_PATH="./mobile-certificates/Certificates"
else
  CERTIFICATES_PATH="../mobile-certificates/Certificates"
fi

# Ensure virtual environment is used
if [ -d ".venv" ]; then
  source .venv/bin/activate
else
  echo "❌ Virtual environment not found!"
  exit 1
fi

python3 $CERTIFICATES_PATH/Palace/iOS/ReleaseNotes.py "$@"
