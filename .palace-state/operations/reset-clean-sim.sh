#!/usr/bin/env bash
# .palace-state/operations/reset-clean-sim.sh
#
# Nuclear-option reset: erases the entire simulator back to factory state
# (all apps, all data, all permissions, all keychain). Boots the sim again
# afterwards. Use when a fresh-install isn't deep enough — e.g. you suspect
# residual keychain state or sim-wide preference drift is influencing test
# behavior.
#
# Required:
#   PALACE_STATE_SIM_UDID  — sim UDID (or --sim <udid>)
#
# Optional:
#   --force                — skip the safety prompt (required in CI/non-tty)
#
# Exit codes:
#   0  sim erased and re-booted
#   1  environment problem (sim doesn't exist)
#   2  erase or boot failed
#   3  invalid arguments
#   5  refused (no --force in non-tty, or user declined the safety prompt)

set -uo pipefail

SIM_UDID="${PALACE_STATE_SIM_UDID:-}"
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim)
      if [ -z "${2:-}" ]; then
        echo "reset-clean-sim: --sim requires an argument" >&2
        exit 3
      fi
      SIM_UDID="$2"
      shift 2
      ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed -n 's/^# *//p'
      exit 0
      ;;
    *) echo "reset-clean-sim: unknown arg: $1" >&2; exit 3 ;;
  esac
done

if [[ -z "$SIM_UDID" ]]; then
  echo "reset-clean-sim: missing sim UDID (set PALACE_STATE_SIM_UDID or pass --sim)" >&2
  exit 3
fi

if ! xcrun simctl list devices 2>/dev/null | grep -q "$SIM_UDID"; then
  echo "reset-clean-sim: sim $SIM_UDID does not exist" >&2
  exit 1
fi

# Safety: this erases EVERYTHING on the sim. If stdin is a terminal and
# --force wasn't passed, prompt. In CI (no tty), require --force explicitly.
# Refusal exits 5 (distinct from 3 invalid-args) so callers can tell apart
# "you typed the command wrong" from "the safety gate stopped you".
if [[ "$FORCE" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    echo "reset-clean-sim: --force required when stdin is not a terminal" >&2
    exit 5
  fi
  echo "About to ERASE sim $SIM_UDID — this deletes all apps, data, and keychain."
  read -r -p "Type 'erase' to confirm: " confirm
  if [[ "$confirm" != "erase" ]]; then
    echo "reset-clean-sim: declined" >&2
    exit 5
  fi
fi

echo "[reset-clean-sim] erasing $SIM_UDID …"

# Shutdown before erase (simctl erase requires a shutdown sim on some Xcode
# versions; on newer Xcode it auto-shuts-down but emits a warning).
xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true

if ! xcrun simctl erase "$SIM_UDID" 2>&1; then
  echo "reset-clean-sim: erase failed" >&2
  exit 2
fi

if ! xcrun simctl boot "$SIM_UDID" 2>&1; then
  echo "reset-clean-sim: boot after erase failed" >&2
  exit 2
fi

# Wait for boot to complete before declaring success.
if ! xcrun simctl bootstatus "$SIM_UDID" 2>&1; then
  echo "reset-clean-sim: boot status check failed" >&2
  exit 2
fi

echo "[reset-clean-sim] OK — sim erased and booted"
