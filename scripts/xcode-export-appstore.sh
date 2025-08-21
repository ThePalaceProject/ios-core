#!/usr/bin/env bash
set -euo pipefail

# Define DEVELOPER_DIR safely before sourcing settings (robust under set -u)
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -n "${MD_APPLE_SDK_ROOT:-}" ]; then
    _sdk_root="${MD_APPLE_SDK_ROOT%/}"
    export DEVELOPER_DIR="${_sdk_root}/Contents/Developer"
  else
    export DEVELOPER_DIR="$([ -x /usr/bin/xcode-select ] && /usr/bin/xcode-select -p 2>/dev/null || true)"
  fi
fi

source "$(dirname "$0")/xcode-settings.sh"

echo "🔧 Using DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p || true)}"
xcodebuild -version
xcodebuild -showsdks

echo "Exporting ${ARCHIVE_NAME} for App Store…"

if ! xcodebuild -showsdks | grep -q "iphoneos"; then
  echo "error: iPhoneOS SDK not found in ${DEVELOPER_DIR:-$(xcode-select -p)}" 1>&2
  xcodebuild -showsdks || true
  exit 70
fi

DERIVED_DATA="${PWD}/Build/DerivedData"
rm -rf "$DERIVED_DATA"

xcodebuild -resolvePackageDependencies \
  -project Palace.xcodeproj \
  -scheme Palace

if ! bundle check > /dev/null 2>&1; then
  echo "Installing Ruby gems with Bundler…"
  bundle config set path 'vendor/bundle'
  bundle install --jobs 4 --retry 3
fi

IOS_SDK_VERSION=$(xcodebuild -version -sdk iphoneos SDKVersion 2>/dev/null || echo "")
DESTINATION_ARG="generic/platform=iOS,name=Any iOS Device (arm64)"

bundle exec fastlane gym \
  --project Palace.xcodeproj \
  --scheme "Palace" \
  --clean \
  --derived_data_path "$DERIVED_DATA" \
  ${IOS_SDK_VERSION:+--sdk iphoneos${IOS_SDK_VERSION}} \
  --destination "$DESTINATION_ARG" \
  --include_symbols true \
  --include_bitcode false \
  --output_directory "$ARCHIVE_DIR" \
  --output_name "${ARCHIVE_NAME}.ipa" \
  --export_method app-store \
  --skip_profile_detection true \
  --export_options '{ "provisioningProfiles": { "org.thepalaceproject.palace": "App Store" } }'
