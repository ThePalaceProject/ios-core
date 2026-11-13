#!/bin/bash
# check-nodrm-app-excludes-audioengine.sh — the built Palace-noDRM.app must run
# without Findaway's AudioEngine SDK, and must not carry it.
#
# WHY. PalaceAudiobookToolkit weak-links AudioEngine.xcframework so one toolkit
# binary serves both the Palace target (which embeds the SDK) and Palace-noDRM
# (which must not ship the proprietary SDK). The build needs the framework
# present to link — scripts/build-carthage.sh fetches it on both paths — but
# nothing in the build itself pins the two properties that make noDRM honest:
#
#   1. Palace-noDRM.app/Frameworks contains no AudioEngine.framework. Adding it
#      to the noDRM "Embed Frameworks" phase would build green and quietly ship
#      Findaway's SDK in the open build.
#   2. The embedded PalaceAudiobookToolkit's load command for AudioEngine is
#      WEAK (or absent). Flipping the link from weak to required also builds
#      green — and the noDRM app then dies at launch with
#      `Library not loaded: @rpath/AudioEngine.framework/AudioEngine`, which no
#      build step can see.
#
# This runs in the public NonDRM Build workflow, so it depends on nothing but
# bash, find and otool — no maintainer-local tooling (prior-art-checked: the
# harness has no post-build product inspector, and could not be used here if
# it did).
#
# USAGE
#   scripts/check-nodrm-app-excludes-audioengine.sh <path/to/Palace-noDRM.app>
#
# EXIT
#   0  clean: no embedded AudioEngine.framework; toolkit link weak or absent
#   1  violation (printed)
#   2  cannot judge: missing argument, app or toolkit binary not found. Absence
#      is not a pass — a build that produced no product has nothing to check.
#
# ENVIRONMENT
#   NODRM_CHECK_OTOOL  command used to list load commands (default `xcrun otool`);
#                      the test suite points it at a fixture.
set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
  echo "usage: $0 <path/to/Palace-noDRM.app>" 1>&2
  exit 2
fi
if [ ! -d "$APP" ]; then
  echo "::error::$APP is not a directory — no product to check (was the build skipped?)" 1>&2
  exit 2
fi

OTOOL="${NODRM_CHECK_OTOOL:-xcrun otool}"
rc=0

# 1. The SDK must not be inside the product, at any depth.
embedded="$(find "$APP" -type d -name 'AudioEngine.framework' 2>/dev/null)"
if [ -n "$embedded" ]; then
  echo "::error::Palace-noDRM.app embeds Findaway's AudioEngine SDK:" 1>&2
  echo "$embedded" | sed 's/^/  /' 1>&2
  echo "  The noDRM product must ship without it. Remove AudioEngine.xcframework from" 1>&2
  echo "  the Palace-noDRM target's Embed Frameworks phase (only Palace embeds it)." 1>&2
  rc=1
fi

# 2. The toolkit must not REQUIRE the SDK at load time.
TOOLKIT="$APP/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit"
if [ ! -f "$TOOLKIT" ]; then
  echo "::error::$TOOLKIT not found — cannot judge how the toolkit links AudioEngine" 1>&2
  exit 2
fi

# `otool -L` prints one line per LC_LOAD*_DYLIB; a weak import ends in
# `, weak)`. The binary is a universal simulator slice set, and otool prints the
# load commands per architecture, so every AudioEngine line must be weak.
load_cmds="$($OTOOL -L "$TOOLKIT" 2>&1)" || {
  echo "::error::$OTOOL -L failed on $TOOLKIT:" 1>&2
  echo "$load_cmds" 1>&2
  exit 2
}
strong="$(printf '%s\n' "$load_cmds" | grep 'AudioEngine\.framework/AudioEngine' | grep -v 'weak)')" || true
if [ -n "$strong" ]; then
  echo "::error::PalaceAudiobookToolkit links AudioEngine as a REQUIRED library:" 1>&2
  echo "$strong" | sed 's/^/  /' 1>&2
  echo "  Palace-noDRM does not embed AudioEngine, so dyld would refuse to launch the app." 1>&2
  echo "  Link it weak (Xcode: Frameworks phase → Status: Optional) so" 1>&2
  echo "  FindawaySupport.isAvailable can turn Findaway off at runtime instead." 1>&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  weak_count="$(printf '%s\n' "$load_cmds" | grep -c 'AudioEngine\.framework/AudioEngine')" || true
  echo "[check-nodrm-app-excludes-audioengine] OK: no embedded AudioEngine.framework; toolkit AudioEngine load commands: ${weak_count:-0} (all weak)"
fi
exit "$rc"
