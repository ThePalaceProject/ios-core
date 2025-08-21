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

echo "Exporting ${ARCHIVE_NAME} for Ad-Hoc distribution…"

# Ensure iPhoneOS SDK is present
if ! xcodebuild -showsdks | grep -q "iphoneos"; then
  echo "error: iPhoneOS SDK not found in ${DEVELOPER_DIR:-$(xcode-select -p)}" 1>&2
  xcodebuild -showsdks || true
  exit 70
fi

# DRY_RUN mode: validate environment and print planned actions without building
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN=1: Skipping build. Environment validated."
  echo "Would run: bundle exec fastlane gym --project Palace.xcodeproj --scheme 'Palace' --clean --derived_data_path '$PWD/Build/DerivedData' --sdk iphoneos --destination 'generic/platform=iOS' --include_symbols true --include_bitcode false --output_directory '$ARCHIVE_DIR' --output_name '${ARCHIVE_NAME}.ipa' --export_method ad-hoc --export_options '{ \"provisioningProfiles\": { \"org.thepalaceproject.palace\": \"Ad Hoc\" } }'"
  exit 0
fi

# Fresh DerivedData
DERIVED_DATA="${PWD}/Build/DerivedData"
rm -rf "$DERIVED_DATA"

# Resolve SPM once (prevents drift)
xcodebuild -resolvePackageDependencies \
  -project Palace.xcodeproj \
  -scheme Palace

# Ensure required Ruby gems (fastlane, etc.) are installed
if ! bundle check > /dev/null 2>&1; then
  echo "Installing Ruby gems with Bundler…"
  bundle install --path vendor/bundle --jobs 4 --retry 3
fi

# Deterministic export: gym with explicit export_method and iOS-only destination
bundle exec fastlane gym \
  --project Palace.xcodeproj \
  --scheme "Palace" \
  --clean \
  --derived_data_path "$DERIVED_DATA" \
  --sdk iphoneos \
  --destination "generic/platform=iOS" \
  --include_symbols true \
  --include_bitcode false \
  --output_directory "$ARCHIVE_DIR" \
  --output_name "${ARCHIVE_NAME}.ipa" \
  --export_method ad-hoc \
  --export_options '{ "provisioningProfiles": { "org.thepalaceproject.palace": "Ad Hoc" } }'

echo "📦 Ad-Hoc .ipa: ${ARCHIVE_DIR}/${ARCHIVE_NAME}.ipa"
echo "Uploading archive…"
"$(dirname "$0")/ios-binaries-upload.sh"
