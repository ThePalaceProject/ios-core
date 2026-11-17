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

AUDIOENGINE_FILENAME="AudioEngine6.5.6.zip"
AUDIOENGINE_ZIP_URL="https://cdn.audioengine.io/ios/$AUDIOENGINE_FILENAME"

# -f: a 4xx/5xx is a failure, not an HTML page saved as a .zip.
curl -fsSL -o "$AUDIOENGINE_FILENAME" "$AUDIOENGINE_ZIP_URL"
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
