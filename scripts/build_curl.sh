#!/bin/bash

# This script builds a static version of
# curl ${CURL_VERSION} for iOS 9.0 that contains code for
# arm64, armv7, arm7s, i386 and x86_64.

# Based off of build script from RMSDK
# Patched by cross-referencing with: https://github.com/sinofool/build-libcurl-ios

set -ex

# Setup paths to stuff we need

CURL_VERSION="7.64.1"

DEVELOPER="/Applications/Xcode.app/Contents/Developer"

SDK_VERSION="12.2"
MIN_VERSION="9.0"

IPHONEOS_PLATFORM="${DEVELOPER}/Platforms/iPhoneOS.platform"
IPHONEOS_SDK="${IPHONEOS_PLATFORM}/Developer/SDKs/iPhoneOS.sdk"
IPHONEOS_GCC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

IPHONESIMULATOR_PLATFORM="${DEVELOPER}/Platforms/iPhoneSimulator.platform"
IPHONESIMULATOR_SDK="${IPHONESIMULATOR_PLATFORM}/Developer/SDKs/iPhoneSimulator.sdk"
IPHONESIMULATOR_GCC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

# Make sure things actually exist

if [ ! -d "$IPHONEOS_PLATFORM" ]; then
  echo "Cannot find $IPHONEOS_PLATFORM"
  exit 1
fi

if [ ! -d "$IPHONEOS_SDK" ]; then
  echo "Cannot find $IPHONEOS_SDK"
  exit 1
fi

if [ ! -x "$IPHONEOS_GCC" ]; then
  echo "Cannot find $IPHONEOS_GCC"
  exit 1
fi

if [ ! -d "$IPHONESIMULATOR_PLATFORM" ]; then
  echo "Cannot find $IPHONESIMULATOR_PLATFORM"
  exit 1
fi

if [ ! -d "$IPHONESIMULATOR_SDK" ]; then
  echo "Cannot find $IPHONESIMULATOR_SDK"
  exit 1
fi

if [ ! -x "$IPHONESIMULATOR_GCC" ]; then
  echo "Cannot find $IPHONESIMULATOR_GCC"
  exit 1
fi

# Clean up whatever was left from our previous build

rm -rf lib include-64
rm -rf /tmp/curl-${CURL_VERSION}-*
rm -f /tmp/curl-${CURL_VERSION}*.log

build()
{
    HOST=$1
    ARCH=$2
    SDK_TYPE=$3
    SDK=$4
    MOREFLAGS=$5
    rm -rf "curl-${CURL_VERSION}"
    unzip "curl-${CURL_VERSION}.zip" -d "."
    pushd .
    cd "curl-${CURL_VERSION}"
    export IPHONEOS_DEPLOYMENT_TARGET=${MIN_VERSION}
    export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${SDK} -miphoneos-version-min=${MIN_VERSION} $MOREFLAGS"
    export CPPFLAGS="-arch ${ARCH} -isysroot ${SDK} -miphoneos-version-min=${MIN_VERSION} $MOREFLAGS"
    export LDFLAGS="-arch ${ARCH} -isysroot ${SDK}"
    ./configure --disable-shared --enable-static --enable-ipv6 --host=${HOST} --prefix="/tmp/curl-${CURL_VERSION}-${ARCH}-${SDK_TYPE}" --with-darwinssl --without-libidn2 --enable-threaded-resolver &> "/tmp/curl-${CURL_VERSION}-${ARCH}-${SDK_TYPE}.log"
    make -j `sysctl -n hw.logicalcpu_max` &> "/tmp/curl-${CURL_VERSION}-${ARCH}-${SDK_TYPE}-build.log"
    make install &> "/tmp/curl-${CURL_VERSION}-${ARCH}-${SDK_TYPE}-install.log"
    popd
    rm -rf "curl-${CURL_VERSION}"
}

build "arm-apple-darwin"    "arm64"  "iphoneos"  "${IPHONEOS_SDK}"  ""
build "x86_64-apple-darwin" "x86_64" "iphonesimulator"  "${IPHONESIMULATOR_SDK}"  "-miphonesimulator-version-min=${MIN_VERSION}"
build "arm-apple-darwin"    "arm64"  "iphonesimulator"  "${IPHONESIMULATOR_SDK}"  "-miphonesimulator-version-min=${MIN_VERSION}"

mkdir -p ../public/ios/lib/-iphoneos ../public/ios/lib/-iphonesimulator ../public/ios/include-64
cp -r /tmp/curl-${CURL_VERSION}-arm64-iphoneos/include/curl ../public/ios/include-64/
lipo \
"/tmp/curl-${CURL_VERSION}-arm64-iphoneos/lib/libcurl.a" \
-create -output ../public/ios/lib/-iphoneos/libcurl.a
lipo \
"/tmp/curl-${CURL_VERSION}-x86_64-iphonesimulator/lib/libcurl.a" \
"/tmp/curl-${CURL_VERSION}-arm64-iphonesimulator/lib/libcurl.a" \
-create -output ../public/ios/lib/-iphonesimulator/libcurl.a

rm -Rf /tmp/curl-${CURL_VERSION}-*
rm -f /tmp/curl-${CURL_VERSION}*.log
