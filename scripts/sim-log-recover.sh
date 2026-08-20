#!/usr/bin/env bash
#
# Recover unified-log evidence from a simulator's own log store WITHOUT
# booting, spawning into, or otherwise touching that simulator.
#
# WHY THIS EXISTS
#
# A QA or chaos pass captures whatever log lines the operator thought to paste
# into a findings row. Everything else is lost the moment the pass ends — and a
# finding backed by one pasted line cannot be re-examined when someone later
# disputes its cause. (In one release regression the run's logs/ tree was empty
# for every device cell, so 41 findings rested entirely on quoted fragments.)
#
# The simulator, however, keeps its own unified-log store on the HOST
# filesystem, independent of whatever the harness captured, and it survives the
# pass. So the evidence is usually still there. This script reads it.
#
# Because it only reads host files, it is safe to run against a simulator that
# another session or agent currently owns — no lock needs to be claimed, and a
# run in progress on that device is not disturbed.
#
# THE SHIM
#
# `log show --archive` refuses any path not ending in .logarchive, and requires
# an Info.plist it can version-check. A simulator's store has neither, so this
# builds a directory of symlinks that satisfies both. Nothing is copied — these
# stores routinely reach hundreds of MB.
#
# TWO CONSTRAINTS THE SHIM IMPOSES, both load-bearing:
#
#   1. Pass --info --debug. CFNetwork task lifecycle (task created / resuming /
#      finished with error / finished successfully) is emitted at Debug level.
#      Without these flags the interesting lines simply are not there, which
#      reads exactly like "the app never made the request."
#
#   2. Do NOT use a process predicate. The shim carries partial metadata, so
#      process names do not resolve and `process == "Palace"` matches nothing —
#      a silent empty result, not an error. Filter on message text instead
#      (this script's optional 4th argument).
#
# The same missing metadata means the app's OWN os_log lines render as
# `<compose failure [UUID]>`. System subsystems come through complete:
# com.apple.CFNetwork, com.apple.network:connection, runningboard, WebKit.
# In practice that is enough to settle network- and lifecycle-shaped questions
# (how many requests were issued, did they succeed, was a process respawned)
# but not to read the app's own narration.
#
# TIME IS LOCAL. Chaos shard directories are named in UTC; the timestamps this
# tool wants are local, so a shard named ...T15-06-59Z is 11:06 in a UTC-4 zone.
# Passing the UTC time yields an empty window and looks like missing data.
#
# EMPTY RESULTS ARE DISAMBIGUATED, NOT JUST REPORTED
#
# A tool whose whole purpose is settling "did the app actually do X" must never
# let an operator error look like a real negative. So on zero output this script
# says WHICH it is:
#
#   exit 0, "0 matches"        the window HAS log data; nothing matched the
#                              pattern. A real negative, safe to reason from.
#   exit 3, "WINDOW NOT COVERED"  the window has no log data at all. Usually a
#                              local-vs-UTC mistake, or a rotated store. Says
#                              nothing about whether the app did X.
#
# Both cases print nothing on stdout, which is why the distinction has to be
# made for the caller rather than left to them.
#
# USAGE
#   scripts/sim-log-recover.sh <UDID> <start> <end> [grep-pattern]
#
#   scripts/sim-log-recover.sh "$UDID" '2026-08-20 11:11:00' '2026-08-20 11:12:00'
#   scripts/sim-log-recover.sh "$UDID" '2026-08-20 11:11:00' '2026-08-20 11:12:00' \
#       'is for <org.thepalaceproject.palace>'
#
# Find the store for a UDID, and its coverage, with:
#   ls -t ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/var/db/diagnostics/Persist
#
set -euo pipefail

# Seams for the fixture test; both default to the production values.
DEVICES_ROOT="${SIM_DEVICES_ROOT:-$HOME/Library/Developer/CoreSimulator/Devices}"
LOG_BIN="${SIM_LOG_BIN:-/usr/bin/log}"

UDID="${1:?usage: sim-log-recover.sh <UDID> <start> <end> [grep-pattern]}"
START="${2:?need start time in LOCAL time, e.g. '2026-08-20 11:11:00'}"
END="${3:?need end time in LOCAL time}"
PATTERN="${4:-}"

DEV="$DEVICES_ROOT/$UDID/data/var/db"
if [ ! -d "$DEV/diagnostics" ]; then
  echo "sim-log-recover: no log store for $UDID" >&2
  echo "  (device deleted, or never booted since creation)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SHIM="$WORK/sim-${UDID:0:8}.logarchive"
mkdir -p "$SHIM"

for n in Persist Special Signpost HighVolume timesync; do
  [ -e "$DEV/diagnostics/$n" ] && ln -s "$DEV/diagnostics/$n" "$SHIM/$n"
done
[ -e "$DEV/uuidtext" ]     && ln -s "$DEV/uuidtext" "$SHIM/uuidtext"
[ -e "$DEV/uuidtext/dsc" ] && ln -s "$DEV/uuidtext/dsc" "$SHIM/dsc"

cat > "$SHIM/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>OSArchiveVersion</key><integer>4</integer></dict></plist>
PLIST

# `log show` warns "partial or missing metadata" on every run here; that is the
# expected cost of the shim, not a failure, so its stderr is dropped.
RAW="$WORK/raw.log"
"$LOG_BIN" show --archive "$SHIM" --start "$START" --end "$END" \
    --style compact --info --debug 2>/dev/null > "$RAW" || true

# `log show` prints a column header even for an empty window; drop it before
# deciding whether the window contained anything.
DATA="$WORK/data.log"
grep -v '^Timestamp  *Ty  *Process' "$RAW" > "$DATA" || true
LINES=$(wc -l < "$DATA" | tr -d ' ')

if [ "$LINES" -eq 0 ]; then
  echo "sim-log-recover: WINDOW NOT COVERED — no log data between $START and $END" >&2
  SPAN_OLD=$(ls -t "$DEV/diagnostics/Persist"/*.tracev3 2>/dev/null | tail -1 || true)
  SPAN_NEW=$(ls -t "$DEV/diagnostics/Persist"/*.tracev3 2>/dev/null | head -1 || true)
  if [ -n "$SPAN_OLD" ] && [ -n "$SPAN_NEW" ]; then
    echo "  store spans roughly $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$SPAN_OLD") .. $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$SPAN_NEW") (LOCAL time)" >&2
  fi
  echo "  times are LOCAL — a chaos shard named ...T15-06-59Z is 11:06 in a UTC-4 zone" >&2
  echo "  this says NOTHING about whether the app did the thing you are looking for" >&2
  exit 3
fi

if [ -z "$PATTERN" ]; then
  cat "$DATA"
  exit 0
fi

HITS="$WORK/hits.log"
grep -E "$PATTERN" "$DATA" > "$HITS" || true
if [ ! -s "$HITS" ]; then
  echo "sim-log-recover: window covered ($LINES lines), 0 matches for: $PATTERN" >&2
  echo "  this IS a real negative — the window has data and nothing matched" >&2
  echo "  (if you grepped an app-emitted string, expect 0: app os_log cannot be" >&2
  echo "   resolved through the shim. Count task UUIDs / connection IDs instead.)" >&2
  exit 0
fi
cat "$HITS"
