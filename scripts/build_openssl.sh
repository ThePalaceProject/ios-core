#!/bin/bash

# This script builds a static version of
# OpenSSL ${OPENSSL_VERSION} for iOS that contains code for
# arm64, armv7, arm7s, i386 and x86_64.
#
# * based on your XCode, set SDK_VERSION below
# * based on openssl version you are using, adjust OPENSSL_VERSION below
#
# * below code is verified on XCode 12.4 and iOS SDK version 13.4
#

set -ex

# Setup paths to stuff we need

OPENSSL_VERSION="1.1.0e"

DEVELOPER="/Applications/Xcode.app/Contents/Developer"

SDK_VERSION="13.4"

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

rm -rf include lib
rm -rf /tmp/openssl-${OPENSSL_VERSION}-*
rm -rf /tmp/openssl-${OPENSSL_VERSION}-*.*log

build()
{
   TARGET=$1
   ARCH=$2
   SDK_TYPE=$3
   GCC=$4
   SDK=$5
   EXTRA=$6
   rm -rf "openssl-${OPENSSL_VERSION}"
   tar xvfz "openssl-${OPENSSL_VERSION}.tar.gz"
   pushd .
   cd "openssl-${OPENSSL_VERSION}"
   sed -i '' "s#'File::Glob' => qw/glob/;#'File::Glob' => qw/bsd_glob/;#g" ./Configure
   sed -i '' "s#'File::Glob' => qw/glob/;#'File::Glob' => qw/bsd_glob/;#g" ./test/build.info 
   ./Configure ${TARGET} no-shared --openssldir="/tmp/openssl-${OPENSSL_VERSION}-${ARCH}-${SDK_TYPE}" --prefix="/tmp/openssl-${OPENSSL_VERSION}-${ARCH}-${SDK_TYPE}" ${EXTRA} &> "/tmp/openssl-${OPENSSL_VERSION}-${ARCH}-${SDK_TYPE}.log"
   perl -i -pe 's|static volatile sig_atomic_t intr_signal|static volatile int intr_signal|' crypto/ui/ui_openssl.c
   perl -i -pe "s|CFLAGS=-DDSO_DLFCN |CFLAGS=-arch ${ARCH} -isysroot ${SDK} -DDSO_DLFCN \$1|g" Makefile
   make -j `sysctl -n hw.logicalcpu_max`
   make install 
   popd
   rm -rf "openssl-${OPENSSL_VERSION}"
}

build "BSD-generic64" "arm64" "iphoneos" "${IPHONEOS_GCC}" "${IPHONEOS_SDK}" ""
build "BSD-generic64" "x86_64" "iphonesimulator" "${IPHONESIMULATOR_GCC}" "${IPHONESIMULATOR_SDK}" "-DOPENSSL_NO_ASM"
build "BSD-generic64" "arm64" "iphonesimulator" "${IPHONESIMULATOR_GCC}" "${IPHONESIMULATOR_SDK}" ""

#

mkdir -p ../public/ios/include
cp -r /tmp/openssl-${OPENSSL_VERSION}-arm64-iphoneos/include/openssl ../public/ios/include/

mkdir -p ../public/ios/lib/-iphoneos ../public/ios/lib/-iphonesimulator
lipo \
	"/tmp/openssl-${OPENSSL_VERSION}-arm64-iphoneos/lib/libcrypto.a" \
	-create -output ../public/ios/lib/-iphoneos/libcrypto.a
lipo \
  "/tmp/openssl-${OPENSSL_VERSION}-arm64-iphonesimulator/lib/libcrypto.a" \
  "/tmp/openssl-${OPENSSL_VERSION}-x86_64-iphonesimulator/lib/libcrypto.a" \
  -create -output ../public/ios/lib/-iphonesimulator/libcrypto.a

lipo \
	"/tmp/openssl-${OPENSSL_VERSION}-arm64-iphoneos/lib/libssl.a" \
	-create -output ../public/ios/lib/-iphoneos/libssl.a
lipo \
  "/tmp/openssl-${OPENSSL_VERSION}-arm64-iphonesimulator/lib/libssl.a" \
  "/tmp/openssl-${OPENSSL_VERSION}-x86_64-iphonesimulator/lib/libssl.a" \
  -create -output ../public/ios/lib/-iphonesimulator/libssl.a

rm -rf /tmp/openssl-${OPENSSL_VERSION}-*
rm -rf /tmp/openssl-${OPENSSL_VERSION}-*.*log
