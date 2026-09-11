#!/bin/bash

# SUMMARY
#   Builds Palace without DRM support.
#
# SYNOPSIS
#   xcode-build-nodrm.sh
#
# USAGE
#   Run this script from the root of Palace ios-core repo, e.g.:
#
#     ./scripts/xcode-build-nodrm.sh
#
# ENVIRONMENT
#   NODRM_DERIVED_DATA_PATH  Optional. When set, passed as -derivedDataPath so
#                            the caller knows where Palace-noDRM.app landed —
#                            CI hands that path to
#                            scripts/check-nodrm-app-excludes-audioengine.sh.

echo "Building Palace without DRM support..."

DERIVED_DATA_ARGS=()
if [ -n "${NODRM_DERIVED_DATA_PATH:-}" ]; then
  DERIVED_DATA_ARGS=(-derivedDataPath "$NODRM_DERIVED_DATA_PATH")
fi

xcodebuild \
  -project Palace.xcodeproj \
  -scheme Palace-noDRM \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  "${DERIVED_DATA_ARGS[@]}" \
  build \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
