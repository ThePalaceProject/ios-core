#!/bin/bash

# Usage: run this script from the root of Palace ios-core repo.
#
#     ./scripts/update-certificates.sh
#
# Note: this script assumes you have the Certificates repo cloned as a sibling of ios-core.

set -eo pipefail

if [ "$BUILD_CONTEXT" == "" ]; then
  echo "Updating repo with info from Certificates repo..."
else
  echo "Updating repo with info from Certificates repo for [$BUILD_CONTEXT]..."
fi

if [ "$BUILD_CONTEXT" == "ci" ]; then
  CERTIFICATES_PATH="./mobile-certificates/Certificates"
else
  CERTIFICATES_PATH="../mobile-certificates/Certificates"
fi

cp Palace/AppInfrastructure/APIKeys.swift.example Palace/AppInfrastructure/APIKeys.swift

# Copy configuration files
cp $CERTIFICATES_PATH/Palace/iOS/GoogleService-Info.plist PalaceConfig/
cp $CERTIFICATES_PATH/Palace/iOS/ReaderClientCert.sig PalaceConfig/

git update-index --skip-worktree Palace/TPPSecrets.swift

# echo "Obfuscating keys..."
swift $CERTIFICATES_PATH/Palace/iOS/KeyObfuscator.swift "$CERTIFICATES_PATH/Palace/iOS/APIKeys.json"

echo "update-certificates: finished"
