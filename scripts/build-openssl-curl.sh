#!/bin/bash

# Usage: run this script from the root of the Palace ios-core repository.
#
# Summary: this script rebuilds OpenSSL 1.0.1u and cURL 7.64.1 which are
#              required by the Adobe RMSDK.
#
# In theory, following the instructions in "adobe-rmsdk/RMSDK_User_Manual(obj).pdf",
# you should be able to build OpenSSL (section 12.1) and cURL (section 12.3)
# since Adobe provides this package to their developers. The following are some
# smoother steps to achieve that.

# Note: if you want/need to use an Xcode installed at a location other than
# /Applications, you'll need to update the $DEVELOPER env variable mentioned
# at the top of both the build.sh / build_curl.sh scripts below.

SDKVERSION=`xcodebuild -version -sdk iphoneos | grep SDKVersion | sed 's/SDKVersion[: ]*//'`

# edit as required if OpenSSL and cURL need updating or retargeting
OPENSSL_VERSION="1.1.0e"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_0e/openssl-1.1.0e.tar.gz"
CURL_VERSION="7.64.1"
CURL_URL="https://curl.se/download/curl-7.64.1.zip"

echo "======================================="
echo "Building OpenSSL..."
cp scripts/build_openssl.sh adobe-rmsdk/thirdparty/openssl/iOS-openssl
pushd adobe-rmsdk/thirdparty/openssl
rm -Rf public/ios
cd iOS-openssl
curl -OL $OPENSSL_URL
sed -i '' "s/OPENSSL_VERSION=\".*\"/OPENSSL_VERSION=\"$OPENSSL_VERSION\"/" build_openssl.sh
sed -i '' "s/SDK_VERSION=\".*\"/SDK_VERSION=\"$SDKVERSION\"/" build_openssl.sh
sed -i '' 's/MIN_VERSION=".*"/MIN_VERSION="9.0"/' build_openssl.sh
bash ./build_openssl.sh  #this will take a while
rm "openssl-${OPENSSL_VERSION}.tar.gz"
rm build_openssl.sh
popd

echo "======================================="
echo "Building cURL..."
cp scripts/build_curl.sh adobe-rmsdk/thirdparty/curl/iOS-libcurl/
pushd adobe-rmsdk/thirdparty/curl
rm -Rf public/ios
cd iOS-libcurl
curl -OL $CURL_URL
sed -i '' "s/CURL_VERSION=\".*\"/CURL_VERSION=\"$CURL_VERSION\"/" build_curl.sh
sed -i '' "s/SDK_VERSION=\".*\"/SDK_VERSION=\"$SDKVERSION\"/" build_curl.sh
sed -i '' 's/MIN_VERSION=".*"/MIN_VERSION="9.0"/' build_curl.sh
bash ./build_curl.sh  #this will take a while
rm "curl-${CURL_VERSION}.zip"
rm build_curl.sh
popd

echo "Finished building OpenSSL and cURL."
