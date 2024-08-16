#!/bin/bash

# Fetch AudioEngine, unzip and copy it into the right directory for building

AUDIOENGINE_FILENAME="AudioEngine6.5.6.zip"
AUDIOENGINE_ZIP_URL="https://cdn.audioengine.io/ios/$AUDIOENGINE_FILENAME"
curl -O $AUDIOENGINE_ZIP_URL
unzip `basename $AUDIOENGINE_ZIP_URL`
mkdir -p Carthage/Build
mv AudioEngine/* Carthage/Build
rm -rf AudioEngine $AUDIOENGINE_FILENAME
