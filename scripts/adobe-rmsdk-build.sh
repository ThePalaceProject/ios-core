#!/bin/bash

# SUMMARY
#   Builds the Adobe SDK, including its dependencies.
#
# USAGE
#   You typically only need to run this script once.
#   Run it from the root of Simplified-iOS, e.g.:
#
#     ./scripts/adobe-rmsdk-build.sh

set -e

echo "Building Adobe RMSDK dependencies..."

./scripts/build-openssl-curl.sh

echo "Building Adobe RMSDK..."

ADOBE_RMSDK="`pwd`/adobe-rmsdk"
CONFIGURATIONS=(Debug Release)
SDKS=(iphoneos iphonesimulator)

for SDK in ${SDKS[@]}; do
  if [ $SDK == "iphoneos" ]; then
    ARCHS="arm64"
  else
    ARCHS="x86_64 arm64"
  fi
  for CONFIGURATION in ${CONFIGURATIONS[@]}; do
    cd "$ADOBE_RMSDK"
    rm lib/ios/${CONFIGURATION}-${SDK}/libdp-iOS.a
    cd "$ADOBE_RMSDK/dp/build/xc5"
    rm -Rf build
    xcodebuild \
      -project dp.xcodeproj \
      -configuration ${CONFIGURATION} \
      -target dp-iOS-noDepend \
      ONLY_ACTIVE_ARCH=NO \
      ENABLE_BITCODE=NO \
      ARCHS="${ARCHS}" \
      VALID_ARCHS="${ARCHS}" \
      IPHONEOS_DEPLOYMENT_TARGET="12.0"\
      -sdk ${SDK} \
      build
    cd "$ADOBE_RMSDK"
    cp \
      dp/build/xc5/Build/${CONFIGURATION}-${SDK}/libdp-iOS.a \
      lib/ios/${CONFIGURATION}-${SDK}
    rm -Rf "$ADOBE_RMSDK/dp/build/xc5/build"
  done
done
