#!/bin/bash

# SUMMARY
#   Unified export driver for The Palace Project archive. Routes ad-hoc and
#   App Store exports through a single entry point so the common pre-export
#   wiring (xcode-settings, changelog read, fastlane invocation) lives in one
#   place instead of being duplicated across xcode-export-{adhoc,appstore}.sh.
#
# SYNOPSIS
#   xcode-export.sh --format <adhoc|appstore>
#
# PARAMETERS
#   --format <adhoc|appstore>   Required. Selects the export pipeline:
#       adhoc      Ad-hoc-signed .ipa, written to $ARCHIVE_DIR/$ARCHIVE_NAME.ipa,
#                  then uploaded via ./scripts/ios-binaries-upload.sh.
#       appstore   App Store-signed .ipa, uploaded to TestFlight by fastlane.
#
#   Additional environment is sourced from xcode-settings.sh — see that file
#   for ARCHIVE_NAME, ARCHIVE_DIR, CHANGELOG_PATH, signing identity etc.
#
# USAGE
#   Run from the root of the ios-core repo:
#
#     ./scripts/xcode-export.sh --format adhoc
#     ./scripts/xcode-export.sh --format appstore
#
#   The two legacy entry points (xcode-export-adhoc.sh / xcode-export-appstore.sh)
#   are kept as thin shims that call this script with the matching --format flag,
#   so existing CI workflows continue to work unchanged.

set -euo pipefail

FORMAT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --format=*)
      FORMAT="${1#--format=}"
      shift
      ;;
    -h|--help)
      sed -n '3,30p' "$0"
      exit 0
      ;;
    *)
      echo "xcode-export.sh: unrecognized argument: $1" >&2
      echo "Usage: xcode-export.sh --format <adhoc|appstore>" >&2
      exit 2
      ;;
  esac
done

if [ -z "$FORMAT" ]; then
  echo "xcode-export.sh: --format is required (adhoc|appstore)" >&2
  exit 2
fi

# Source common build settings (ARCHIVE_NAME, ARCHIVE_DIR, CHANGELOG_PATH,
# signing identity, etc.). Both export paths need these — keep the source
# call out of the per-format branches.
# shellcheck disable=SC1091
source "$(dirname "$0")/xcode-settings.sh"

case "$FORMAT" in
  adhoc)
    echo "Exporting $ARCHIVE_NAME for Ad-Hoc distribution..."
    # Use fastlane from runner environment
    fastlane ios beta output_name:"$ARCHIVE_NAME.ipa" export_path:"$ARCHIVE_DIR"

    echo "Uploading archive:"
    ./scripts/ios-binaries-upload.sh
    ;;

  appstore)
    echo "Exporting $ARCHIVE_NAME for App Store distribution..."
    CHANGELOG=$(<"$CHANGELOG_PATH")
    # Use fastlane from runner environment
    fastlane ios appstore changelog:"$CHANGELOG"
    ;;

  *)
    echo "xcode-export.sh: unknown --format '$FORMAT' (expected adhoc|appstore)" >&2
    exit 2
    ;;
esac
