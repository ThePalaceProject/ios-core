#!/bin/bash
#
# PP-5219 — drive a GENUINE first launch with an MDM configuration already
# waiting, on a simulator.
#
# prior-art-checked: `harness capabilities` offers sim ALLOCATION (harness test,
# harness sim claim) and UI DRIVING (simdrive), and this script uses neither's
# job. What it does is seed Apple's managed-configuration dictionary into an
# app's data container between install and first launch — impersonating the MDM
# at the one moment that cannot be reproduced from inside a running app. Nothing
# in the harness writes an app container, and simdrive starts after launch, which
# is after the window this exists to exercise.
#
# ## Why this is a script rather than a note in a ticket
#
# Every check of this feature so far was made on an app that was already open
# with its library list already loaded, where the configured library resolved
# instantly. That is the one launch the feature is NOT for. The launch that
# matters is a student taking a school iPad out of a cart: an app that has never
# run, a configuration already pushed to it, and a library list that is months
# stale until the network answers. The behaviour we rely on in production was
# the behaviour we had never once observed.
#
# It has to be repeatable because it will need re-running whenever launch
# behaviour changes, and because getting it wrong is easy in a way that looks
# like success — see the two traps below.
#
# ## Trap one: "first launch" is not "app not currently open"
#
# A previously-run app has a data container full of state, including a selected
# library and the fingerprint of any configuration already applied. Relaunching
# it exercises the ALREADY-APPLIED path, which is not this. Only
# `simctl uninstall` removes the container outright, and that is what a device
# out of a cart actually looks like.
#
# ## Trap two: the configuration cannot be written with `defaults`
#
# A sandboxed iOS app's defaults live in its data container, not in the domain
# `simctl spawn ... defaults` consults — which reports "does not exist" for
# values that are plainly there, and has already caused one session here to
# silently measure the wrong cell. The plist is written directly instead, and
# read back before launching, because a silent write failure would produce a run
# that looks exactly like the feature not working.
#
# Writing it AFTER install and BEFORE first launch is the whole point: that is
# the ordering an MDM produces, and the ordering under which the app's bundled
# library list cannot yet contain the configured library.
#
# ## Usage
#
#   scripts/mdm-first-launch.sh --app <path to Palace.app> \
#       --library urn:uuid:... [--udid <sim>] [--flag on|off] \
#       [--expect applied|picker|ignored]
#
# Copyright © 2026 The Palace Project. All rights reserved.

set -uo pipefail

BUNDLE_ID="org.thepalaceproject.palace"
MANAGED_KEY="com.apple.configuration.managed"
FLAG_KEY="RemoteFeatureFlags.managedLibraryConfigurationLocalOverride"
SELECTED_KEY="TPPCurrentAccountIdentifier"
APPLIED_KEY="TPPManagedLibraryAppliedFingerprint"

APP=""
UDID=""
LIBRARY=""
EXPECT="applied"
SETTLE=25
FLAG="on"
ADDITIONAL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)     APP="$2"; shift 2 ;;
    --udid)    UDID="$2"; shift 2 ;;
    --library) LIBRARY="$2"; shift 2 ;;
    --expect)  EXPECT="$2"; shift 2 ;;
    --settle)  SETTLE="$2"; shift 2 ;;
    --flag)    FLAG="$2"; shift 2 ;;
    --additional) ADDITIONAL="$2"; shift 2 ;;
    -h|--help) sed -n '3,52p' "$0"; exit 0 ;;
    *) echo "unrecognized argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$APP" ] || { echo "--app is required (path to a built Palace.app)" >&2; exit 2; }
[ -d "$APP" ] || { echo "not a bundle: $APP" >&2; exit 2; }
[ -n "$LIBRARY" ] || { echo "--library is required" >&2; exit 2; }

if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices booted -j \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for runtime in d.values():
    for dev in runtime:
        if dev.get("state")=="Booted":
            print(dev["udid"]); raise SystemExit')
fi
[ -n "$UDID" ] || { echo "no booted simulator; pass --udid" >&2; exit 2; }

echo "sim:     $UDID"
echo "app:     $APP"
echo "library: $LIBRARY"
echo "expect:  $EXPECT"
echo

# ---------------------------------------------------------------- clean slate
echo "==> uninstalling (removes the data container outright)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
echo "==> installing"
xcrun simctl install "$UDID" "$APP" || exit 1

CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)
[ -n "$CONTAINER" ] || { echo "no data container after install" >&2; exit 1; }
PREFS="$CONTAINER/Library/Preferences"
PLIST="$PREFS/$BUNDLE_ID.plist"
mkdir -p "$PREFS"
[ -f "$PLIST" ] || /usr/libexec/PlistBuddy -c "Save" "$PLIST" >/dev/null 2>&1

# ------------------------------------------------- the MDM's half, pre-launch
echo "==> writing the managed configuration (before first launch)"
/usr/libexec/PlistBuddy -c "Delete :$MANAGED_KEY" "$PLIST" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :$MANAGED_KEY dict" "$PLIST" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :$MANAGED_KEY:defaultLibraryId string $LIBRARY" "$PLIST" >/dev/null 2>&1

# A school with divisions pushes one selected library plus the others to add
# without selecting. Comma-separated here; an array in the real payload.
if [ -n "$ADDITIONAL" ]; then
  /usr/libexec/PlistBuddy -c "Add :$MANAGED_KEY:additionalLibraryIds array" "$PLIST" >/dev/null 2>&1
  i=0
  IFS=',' read -r -a EXTRA <<< "$ADDITIONAL"
  for id in "${EXTRA[@]}"; do
    /usr/libexec/PlistBuddy -c "Add :$MANAGED_KEY:additionalLibraryIds:$i string $id" "$PLIST" >/dev/null 2>&1
    i=$((i+1))
  done
fi

# The feature is flagged off by default, so without this the launch path ignores
# the configuration entirely and the run measures the OFF behaviour while
# looking exactly like a failure of the feature.
#
# `--flag off` exists to measure that deliberately, and it is not a formality.
# Side loading shipped in 3.3.0 with a local-override key that nothing outside
# the tests ever wrote: the feature was unreachable and looked, from the code,
# exactly like a feature that worked. The only thing that distinguishes "flagged
# off" from "wired to nothing" is running both and seeing them differ.
/usr/libexec/PlistBuddy -c "Delete :$FLAG_KEY" "$PLIST" >/dev/null 2>&1
if [ "$FLAG" = "on" ]; then
  /usr/libexec/PlistBuddy -c "Add :$FLAG_KEY bool true" "$PLIST" >/dev/null 2>&1
else
  /usr/libexec/PlistBuddy -c "Add :$FLAG_KEY bool false" "$PLIST" >/dev/null 2>&1
fi

echo "--- container plist as the app will first see it ---"
plutil -p "$PLIST"
echo "---------------------------------------------------"

WROTE=$(/usr/libexec/PlistBuddy -c "Print :$MANAGED_KEY:defaultLibraryId" "$PLIST" 2>/dev/null)
if [ "$WROTE" != "$LIBRARY" ]; then
  echo "FAIL: configuration did not land in the container (read back: '$WROTE')" >&2
  exit 1
fi
FLAG_WROTE=$(/usr/libexec/PlistBuddy -c "Print :$FLAG_KEY" "$PLIST" 2>/dev/null)
EXPECT_FLAG=$([ "$FLAG" = "on" ] && echo true || echo false)
if [ "$FLAG_WROTE" != "$EXPECT_FLAG" ]; then
  echo "FAIL: feature flag override did not land (wanted $EXPECT_FLAG, read back: '$FLAG_WROTE')" >&2
  exit 1
fi

# Nothing may be selected or applied yet. If either is set, the container was
# not clean and whatever this run reports afterwards is about the wrong launch.
for k in "$SELECTED_KEY" "$APPLIED_KEY"; do
  existing=$(/usr/libexec/PlistBuddy -c "Print :$k" "$PLIST" 2>/dev/null)
  if [ -n "$existing" ]; then
    echo "FAIL: '$k' was already '$existing' before launch — this is not a first launch" >&2
    exit 1
  fi
done

# ------------------------------------------------------------------- observe
echo "==> launching, settling for ${SETTLE}s"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || { echo "launch failed" >&2; exit 1; }
sleep "$SETTLE"

echo
echo "==> what the app settled on"
SELECTED=$(/usr/libexec/PlistBuddy -c "Print :$SELECTED_KEY" "$PLIST" 2>/dev/null)
APPLIED=$(/usr/libexec/PlistBuddy -c "Print :$APPLIED_KEY" "$PLIST" 2>/dev/null)
ADDED=$(/usr/libexec/PlistBuddy -c "Print :NYPLSettingsLibraryAccountsKey" "$PLIST" 2>/dev/null | tr -d ' \n')
echo "selected library:       ${SELECTED:-<none>}"
echo "applied configuration:  ${APPLIED:-<none>}"
echo "added libraries:        ${ADDED:-<none>}"

# When extra libraries were configured, the selected one landing is only half
# the claim. A run that reports PASS while silently adding none would be the
# multiple-library feature failing behind a green result.
if [ -n "$ADDITIONAL" ] && [ "$EXPECT" = "applied" ]; then
  IFS=',' read -r -a WANTED <<< "$ADDITIONAL"
  for id in "${WANTED[@]}"; do
    case "$ADDED" in
      *"$id"*) ;;
      *) echo "FAIL: configured extra library $id was not added (added: ${ADDED:-<none>})"; exit 1 ;;
    esac
  done
  echo "all ${#WANTED[@]} configured extra librar(y/ies) were added"
fi

case "$EXPECT" in
  applied)
    if [ "$SELECTED" = "$LIBRARY" ]; then
      echo "PASS: opened into the configured library with no manual step"
      exit 0
    fi
    echo "FAIL: expected $LIBRARY, got '${SELECTED:-<none>}'"
    exit 1
    ;;
  picker)
    # The deliberately-wrong-identifier case. What must NOT happen is the app
    # sitting on a blank catalog forever; it has to reach a usable state, which
    # means no library selected and the picker free to appear.
    if [ -z "$SELECTED" ] && [ -z "$APPLIED" ]; then
      echo "PASS: nothing was selected or recorded, as expected for an unresolvable configuration"
      exit 0
    fi
    echo "FAIL: selected='${SELECTED:-<none>}' applied='${APPLIED:-<none>}' for a configuration that should not resolve"
    exit 1
    ;;
  ignored)
    # Flag off. The configuration is present and correct and must be ignored
    # entirely: nothing selected, nothing recorded. A run that selects here
    # means the flag is not gating the launch path.
    if [ -z "$SELECTED" ] && [ -z "$APPLIED" ]; then
      echo "PASS: a valid configuration was ignored with the flag off"
      exit 0
    fi
    echo "FAIL: the flag is not gating this — selected='${SELECTED:-<none>}' applied='${APPLIED:-<none>}'"
    exit 1
    ;;
  *)
    echo "unknown --expect '$EXPECT' (applied|picker|ignored)" >&2; exit 2 ;;
esac
