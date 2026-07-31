#!/usr/bin/env bash
#
# check-machine-quiet.sh — refuse to trust a test run on an overloaded machine.
#
# During the 3.2.3 LCP hotfix the full suite went red six times with a DIFFERENT
# unrelated test failing each run, every one passing in isolation. That was
# diagnosed five separate times as test pollution, as a parallel-clone starvation
# flake, and — wrongly, in a commit message — as a regression introduced by the
# branch itself. A control experiment was run and misread, because the control
# measured available CPU rather than the change under test.
#
# The actual cause was 22 runaway shell processes consuming ~1959% CPU, about 20
# of 24 cores, some of them a week old. One `uptime` would have explained every
# observation. Nobody ran it, for hours.
#
# Deadline-poll tests are the first thing to die under contention, which is why
# the failure lands somewhere different every run and always survives isolation —
# the exact signature that reads as "known flake" and gets waved through.
#
# So: check before you measure, and say so out loud. A red suite on a loaded
# machine is not evidence about your code, and neither is a green one.
#
# Usage:
#   scripts/check-machine-quiet.sh                 # advisory, exit 0 unless --strict
#   scripts/check-machine-quiet.sh --strict        # exit 1 when too loaded to trust
#   scripts/check-machine-quiet.sh --max-ratio 0.5
#
# Default threshold: 1-minute load average above 60% of core count. Xcode's own
# parallel clones push load legitimately high, so this is about the load present
# BEFORE your run starts.

set -euo pipefail

MAX_RATIO="0.6"
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)    STRICT=1; shift ;;
    --max-ratio) MAX_RATIO="$2"; shift 2 ;;
    -h|--help)   sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)
LOAD1=$(uptime | sed -E 's/.*averages?: *//' | awk '{print $1}' | tr -d ',')
RATIO=$(python3 -c "print(f'{float('$LOAD1')/float('$CORES'):.2f}')")
LIMIT=$(python3 -c "print(f'{float('$CORES')*float('$MAX_RATIO'):.1f}')")

OVER=$(python3 -c "print(1 if float('$LOAD1') > float('$LIMIT') else 0)")

if [[ "$OVER" == "0" ]]; then
  echo "machine-quiet: load ${LOAD1} on ${CORES} cores (ratio ${RATIO}) — OK to measure"
  exit 0
fi

echo ""
echo "machine-quiet: LOAD ${LOAD1} ON ${CORES} CORES (ratio ${RATIO}, limit ${LIMIT})"
echo ""
echo "  A test result measured now is not evidence about your code. Deadline-poll"
echo "  tests starve first, so you will get a different unrelated failure each run,"
echo "  each passing in isolation — which looks exactly like a known flake."
echo ""
echo "  Top consumers:"
# `| head` closes the pipe early, so under `set -o pipefail` the producer dies
# with SIGPIPE and takes the whole script's exit code with it (141, not 1).
ps -Ao %cpu,etime,comm -r 2>/dev/null | sed -n '1,8p' | sed 's/^/    /'
echo ""

STALE_SHELLS=$(ps -Ao etime,command 2>/dev/null \
  | grep -c "/bin/zsh -c source .*shell-snapshots" || true)
if [[ "${STALE_SHELLS:-0}" -gt 2 ]]; then
  echo "  ${STALE_SHELLS} agent shell processes are running. Long-lived ones are"
  echo "  usually abandoned polling loops from earlier sessions:"
  echo "    pgrep -fl 'shell-snapshots' | head"
  echo "  Check none belong to a live session before killing them."
  echo ""
fi

if [[ "$STRICT" == "1" ]]; then
  echo "machine-quiet: refusing to run (--strict). Quiet the machine and retry."
  exit 1
fi

echo "machine-quiet: continuing anyway — treat the result as UNTRUSTED."
exit 0
