#!/bin/bash

# SUMMARY
#   Fetch Findaway's AudioEngine SDK, unzip it and put the xcframework where
#   PalaceAudiobookToolkit links it (Carthage/Build/AudioEngine.xcframework).
#
# USAGE
#   Run from the root of ios-core. Called by scripts/build-carthage.sh for both
#   the DRM and the --no-private (noDRM) paths: the download is public and
#   needs no credentials.
#
# EXIT STATUS
#   Non-zero on any failed step. `set -e` matters here: the last command used
#   to be `rm -rf`, so a failed download still exited 0 and the failure only
#   surfaced later as a missing-xcframework build error.

set -euo pipefail

# The version and the SHA-256 of its archive are the record of this download.
# To move to a new version, change both together: download the new archive,
# take `shasum -a 256` of it, and check that a DRM build plays a Findaway title.
AUDIOENGINE_VERSION="6.5.6"
AUDIOENGINE_SHA256="debe3f1c10d71ae31160418587560352eced166e176cbb040828d020bba66786"
AUDIOENGINE_FILENAME="AudioEngine$AUDIOENGINE_VERSION.zip"
AUDIOENGINE_ZIP_URL="https://cdn.audioengine.io/ios/$AUDIOENGINE_FILENAME"

# -f: a 4xx/5xx is a failure, not an HTML page saved as a .zip.
curl -fsSL -o "$AUDIOENGINE_FILENAME" "$AUDIOENGINE_ZIP_URL"
# The CDN serves the archive by file name only, so the hash is what ties the
# bytes to the version recorded above.
actual_sha256="$(shasum -a 256 "$AUDIOENGINE_FILENAME" | cut -d' ' -f1)"
if [ "$actual_sha256" != "$AUDIOENGINE_SHA256" ]; then
  rm -f "$AUDIOENGINE_FILENAME"
  echo "$0: $AUDIOENGINE_ZIP_URL has SHA-256 $actual_sha256, expected $AUDIOENGINE_SHA256" 1>&2
  echo "$0: the archive changed; update AUDIOENGINE_SHA256 only after checking the new archive" 1>&2
  exit 1
fi
# -o: never prompt to overwrite a leftover from an interrupted run.
unzip -q -o "$AUDIOENGINE_FILENAME"
mkdir -p Carthage/Build
# mv cannot merge into an existing directory, so replace each entry outright —
# a re-run over a populated Carthage/Build must succeed, not stop at
# "Directory not empty".
for entry in AudioEngine/*; do
  rm -rf "Carthage/Build/$(basename "$entry")"
  mv "$entry" Carthage/Build/
done
rm -rf AudioEngine "$AUDIOENGINE_FILENAME"

[ -d Carthage/Build/AudioEngine.xcframework ] || {
  echo "$0: the archive did not contain AudioEngine.xcframework" 1>&2
  exit 1
}
