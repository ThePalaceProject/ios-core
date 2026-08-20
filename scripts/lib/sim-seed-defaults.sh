#!/usr/bin/env bash
# sim-seed-defaults.sh — seed a UserDefaults key WHERE THE APP ACTUALLY READS IT,
# and prove it landed. Sourced, not executed.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
# ─────────────────────────────────────────────────────────────────────────────
# `xcrun simctl spawn <udid> defaults write <bundle-id> <key> …` looks exactly
# like the thing you want and is not. It writes the SIMULATOR HOST's preference
# domain, not the app's sandboxed container, so `@AppStorage("<key>")` — which
# reads UserDefaults.standard INSIDE the container — never sees it. The command
# succeeds. It prints nothing. The caller then prints "✓ seeded" and the operator
# proceeds on a belief that is false.
#
# That is the same shape as every other failure in the 2026-08-20 regression:
# a success MESSAGE printed after an unverified side effect. The fix is not a
# better message — it is to write to the container plist and then READ IT BACK.
#
#   container plist:
#     $(xcrun simctl get_app_container <udid> <bid> data)/Library/Preferences/<bid>.plist
#
# Two constraints that are not optional:
#   1. The app must be TERMINATED. A running app's cfprefsd holds the domain and
#      will flush its own cached copy over anything written underneath it.
#   2. Read back with a DIFFERENT tool than the one that wrote. PlistBuddy
#      writing and PlistBuddy reading agree with each other by construction even
#      when the file is not the one the app opens; PlistBuddy writes and
#      `plutil -extract` reads is an independent check of the bytes on disk.
#
# What the read-back does NOT prove: that the app's cfprefsd had not already
# cached an older domain for this boot. Nothing short of launching and observing
# proves that. So seed BEFORE first launch, and treat a post-launch
# disappearance as a real failure (see verify_app_default_bool).

# app_prefs_plist <udid> <bundle-id>
# Echoes the container preferences plist path. Non-zero if the app is not
# installed (get_app_container fails) — which is itself worth failing on.
app_prefs_plist() {
  local udid="$1" bid="$2" data
  data="$(xcrun simctl get_app_container "$udid" "$bid" data 2>/dev/null)" || return 1
  [ -n "$data" ] || return 1
  printf '%s/Library/Preferences/%s.plist\n' "$data" "$bid"
}

# read_app_default_bool <plist> <key>
# Echoes "true"/"false" from the plist, or nothing when the key is absent.
# Uses plutil deliberately — see the note above about tool independence.
read_app_default_bool() {
  local plist="$1" key="$2" raw
  [ -f "$plist" ] || return 1
  raw="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null)" || return 1
  case "$raw" in
    1|true|YES|yes)  printf 'true\n' ;;
    0|false|NO|no)   printf 'false\n' ;;
    *)               printf '%s\n' "$raw" ;;
  esac
}

# seed_app_default_bool <plist> <key> <true|false>
# Writes the key with PlistBuddy and VERIFIES it by reading the file back with
# plutil. Returns 0 only when the value is present and correct on disk; prints a
# diagnosis to stderr otherwise. Never prints a success claim it has not checked.
seed_app_default_bool() {
  local plist="$1" key="$2" want="$3" dir got
  case "$want" in
    true|YES|yes|1)   want="true" ;;
    false|NO|no|0)    want="false" ;;
    *) echo "seed_app_default_bool: value must be a bool, got '$want'" >&2; return 2 ;;
  esac

  dir="$(dirname "$plist")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "seed_app_default_bool: cannot create $dir" >&2
    return 1
  fi
  if [ ! -f "$plist" ]; then
    /usr/libexec/PlistBuddy -c "Save" "$plist" >/dev/null 2>&1 || true
  fi
  /usr/libexec/PlistBuddy -c "Add :$key bool $want" "$plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :$key $want" "$plist" >/dev/null 2>&1 \
    || true

  got="$(read_app_default_bool "$plist" "$key" || true)"
  if [ "$got" = "$want" ]; then
    return 0
  fi
  echo "seed_app_default_bool: read-back FAILED for '$key' in $plist" >&2
  echo "  wanted: $want" >&2
  echo "  got:    ${got:-<key absent>}" >&2
  return 1
}

# verify_app_default_bool <plist> <key> <true|false>
# Re-read only — for asserting a previously-seeded value survived a launch.
verify_app_default_bool() {
  local plist="$1" key="$2" want="$3" got
  case "$want" in
    true|YES|yes|1)  want="true" ;;
    false|NO|no|0)   want="false" ;;
  esac
  got="$(read_app_default_bool "$plist" "$key" || true)"
  [ "$got" = "$want" ]
}
