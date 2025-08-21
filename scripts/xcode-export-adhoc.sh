#!/usr/bin/env bash
set -euo pipefail

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

# Fresh DerivedData
DERIVED_DATA="${PWD}/Build/DerivedData"
rm -rf "$DERIVED_DATA"

# Resolve SPM once (prevents drift)
xcodebuild -resolvePackageDependencies \
  -project Palace.xcodeproj \
  -scheme Palace

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
