#!/usr/bin/env python3
"""Tap a simulator the moment a log event fires, instead of after a fixed delay.

WHY THIS EXISTS

Some behaviours only occur when input arrives inside a window that opens and
closes on its own schedule. A regression campaign hit one: a download-button
defect that reproduces only if a tap lands while a content transfer is in
flight. That window is 1.2-3.0s wide and opens 6-11s after the borrow, and the
lag varies per title and per network. Fixed-delay scripting cannot reliably hit
it, so repeated attempts all missed — and a cell that is missed looks exactly
like a cell that is negative.

That difference matters more than the tap does. "We tapped and nothing
happened" retires a hypothesis; "we never landed a tap in the window" does not.
This tool exists so the distinction can be made honestly: it either reports the
tap WITH its measured latency from the triggering event, or it reports that the
trigger never fired and refuses to imply anything about the behaviour.

HOW

`log stream` on the device is the event source rather than a UI poll, for two
reasons: it fires on the actual state change instead of a proxy for it, and it
delivers in ~0.1-0.3s where an observe round-trip costs seconds — most of the
window. The tap goes through simdrive's HID injector directly, not over MCP, to
keep the same budget.

Unlike scripts/sim-log-recover.sh, this DOES run a process on the device
(`simctl spawn ... log stream`), so it requires owning the simulator.

EXIT CODES
  0  trigger fired and the tap was injected (or reported, under --dry-run)
  4  trigger never fired within --timeout. Says NOTHING about the behaviour
     under test — the window may simply never have opened.
  1  usage / environment problem (no HID injector, bad arguments)
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import time

# The default trigger: CFNetwork announcing a task created on the app's
# background download session. This is the transfer START, not a UI proxy.
DEFAULT_CONTAINS = "is for <org.thepalaceproject.palace>"
DEFAULT_PATTERN = r"Task <[0-9A-Fa-f-]+>\.<\d+> is for <org\.thepalaceproject\.palace>"


def build_stream_cmd(udid: str, contains: str) -> str:
    predicate = f'eventMessage CONTAINS "{contains}"'
    return (
        f"xcrun simctl spawn {shlex.quote(udid)} log stream "
        f"--style compact --level debug --predicate {shlex.quote(predicate)}"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--x", type=float, required=True, help="tap X in POINTS (not pixels)")
    ap.add_argument("--y", type=float, required=True, help="tap Y in POINTS (not pixels)")
    ap.add_argument("--contains", default=DEFAULT_CONTAINS,
                    help="substring for the device-side log predicate (cheap server-side filter)")
    ap.add_argument("--pattern", default=DEFAULT_PATTERN,
                    help="regex the streamed line must match to count as the trigger")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--dry-run", action="store_true",
                    help="report the trigger and the latency budget without tapping")
    ap.add_argument("--stream-cmd", default=None,
                    help="override the event source (test seam; defaults to simctl log stream)")
    args = ap.parse_args()

    tap = None
    if not args.dry_run:
        try:
            from simdrive import hid_inject  # type: ignore
        except Exception as exc:  # pragma: no cover - import shape varies by install
            print(f"sim-tap-on-event: cannot import simdrive.hid_inject: {exc}", file=sys.stderr)
            return 1
        if not hid_inject.available():
            print("sim-tap-on-event: simdrive HID injector unavailable", file=sys.stderr)
            return 1
        tap = hid_inject.tap

    cmd = args.stream_cmd or build_stream_cmd(args.udid, args.contains)
    rx = re.compile(args.pattern)
    started = time.monotonic()

    proc = subprocess.Popen(
        cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            if time.monotonic() - started > args.timeout:
                break
            if not rx.search(line):
                continue
            t_event = time.monotonic()
            if tap is not None:
                tap(args.udid, args.x, args.y)
            t_tap = time.monotonic()
            print(json.dumps({
                "triggered": True,
                "tapped": tap is not None,
                "trigger_line": line.strip()[:240],
                # The number that decides whether the attempt is usable: if this
                # approaches the width of the window being targeted, the tap may
                # have landed outside it and the result must not be read as a
                # negative.
                "latency_s": round(t_tap - t_event, 4),
                "waited_s": round(t_event - started, 3),
            }))
            return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:  # pragma: no cover
            proc.kill()

    print(json.dumps({
        "triggered": False,
        "tapped": False,
        "waited_s": round(time.monotonic() - started, 3),
        "note": "trigger never fired; this says NOTHING about the behaviour under test",
    }))
    print("sim-tap-on-event: TRIGGER NEVER FIRED — the window may never have opened.", file=sys.stderr)
    print("  Do NOT record the target behaviour as refuted on this run.", file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
