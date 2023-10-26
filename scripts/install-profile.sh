# Install distribution profile.
#
# The process is described here:
# https://docs.github.com/en/actions/guides/installing-an-apple-certificate-on-macos-runners-for-xcode-development

# To encode Apple Provisioning Profile and Certificate you can use base64 system
# For example: base64 certificate.p12 > encodedCertificate.txt
# echo -n "<your secret that includes encoded certificate>" | base64 --decode --output <certificate name>.p12
# echo -n "<your secret that includes encoded provision profile>" | base64 --decode --output <profile name>.mobileprovision

set -eo pipefail

# create variables
CERTIFICATE_PATH=$RUNNER_TEMP/build_certificate.p12
ASPP_PATH=$RUNNER_TEMP/build_aspp.mobileprovision
AHPP_PATH=$RUNNER_TEMP/build_ahpp.mobileprovision
KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db

# import certificate and provisioning profile from secrets
echo -n "$CI_DISTRIBUTION_CERT_BASE64" | base64 --decode -o $CERTIFICATE_PATH
echo -n "$CI_APPSTORE_MP_BASE64" | base64 --decode -o $ASPP_PATH
echo -n "$CI_ADHOC_MP_BASE64" | base64 --decode -o $AHPP_PATH

# create temporary keychain
security create-keychain -p "$CI_KEYCHAIN_PW" $KEYCHAIN_PATH
security set-keychain-settings -lut 21600 $KEYCHAIN_PATH
security unlock-keychain -p "$CI_KEYCHAIN_PW" $KEYCHAIN_PATH

# import certificate to keychain
security import $CERTIFICATE_PATH -P "" -A -t cert -f pkcs12 -k $KEYCHAIN_PATH
security list-keychain -d user -s $KEYCHAIN_PATH

# apply provisioning profile
mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
cp $ASPP_PATH ~/Library/MobileDevice/Provisioning\ Profiles
cp $AHPP_PATH ~/Library/MobileDevice/Provisioning\ Profiles

# save App Store API key
echo $CI_APPLE_FASTLANE_JSON > fastlane/fastlane.json
