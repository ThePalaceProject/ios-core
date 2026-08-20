#!/usr/bin/env python3
"""Compare a signature across two builds, and REFUSE to compare when it is invalid.

WHY

Counting a log signature on two builds produces a number whether or not the
number means anything. A regression campaign produced two clean-looking zeros
that meant nothing:

  - a baseline zero from a lane that was never rendered, and
  - a baseline zero from a search that used a different input class than the
    candidate's.

Both would have been filed. One would have been a false REGRESSION on a
release-gating row. In each case three of the four preconditions held and the
fourth was silently absent, which is exactly the shape that survives review: a
result that looks measured.

So this tool checks the preconditions FIRST and emits no comparison at all
unless every one of them holds:

  1. DEVICE model matches between the two sides
  2. OS version matches
  3. WITNESS present on the CANDIDATE side  (the path ran)
  4. WITNESS present on the BASELINE side   (the path ran there too), at a
     COMPARABLE DENSITY — see below

Input-class equality (same string, same lane, same content) cannot be checked
mechanically — that is what the witness pattern is for. Choose a witness that
can only appear if the specific path under test actually executed: a request to
the host whose covers fail, the query string itself, a task on the session that
matters. A witness like "the app launched" satisfies the check and defeats it.

"PRESENT" IS NOT ENOUGH, and this tool learned that the hard way. Run against
the real pair it was written for, the first version PASSED it: the baseline had
three incidental mentions of the witness host while never rendering the lane,
so a >0 check let a 53-vs-0 comparison through — the exact false REGRESSION the
tool exists to prevent. Window lengths differ by orders of magnitude between a
20-second shard and a 5-minute pass, so raw counts do not compare either. The
check is therefore on DENSITY (witness hits per 1000 log lines), and a side
whose density is a small fraction of the other's is treated as not having run
the path. Set --min-witness above 1 whenever you know roughly how many hits a
genuine exercise produces.

EXIT CODES
  0  preconditions held; comparison emitted
  5  a precondition failed; NO comparison emitted, and the failure is named
  1  usage / environment problem
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_RECOVER = str(Path(__file__).resolve().parent / "sim-log-recover.sh")


def device_of(udid: str, simctl_json: str | None) -> tuple[str, str, str]:
    """Return (device_type_identifier, os_version, display_name) for a UDID.

    The TYPE identifier is what the device check compares, never the name. A
    purpose-built baseline simulator is routinely given a custom name
    ("baseline-ipad11m5-261") while being the same device type as the candidate
    cell it is meant to match — comparing names refuses those pairs, which is a
    false DEVICE-MISMATCH on exactly the comparison the tool exists to make.
    The name is carried only so the output is readable.
    """
    if simctl_json:
        blob = json.loads(Path(simctl_json).read_text())
    else:
        out = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"],
                             capture_output=True, text=True, check=True).stdout
        blob = json.loads(out)
    for runtime, devices in blob.get("devices", {}).items():
        for d in devices:
            if d.get("udid", "").upper() == udid.upper():
                os_ver = runtime.split(".")[-1].replace("iOS-", "").replace("-", ".")
                dtype = d.get("deviceTypeIdentifier") or ""
                if not dtype:
                    raise KeyError(f"no deviceTypeIdentifier for {udid}; cannot compare device type")
                return dtype, os_ver, d.get("name", "?")
    raise KeyError(f"UDID not found in simctl output: {udid}")


def read_window(recover: str, udid: str, start: str, end: str) -> str:
    r = subprocess.run([recover, udid, start, end], capture_output=True, text=True)
    # exit 3 = window not covered; that is a precondition failure, not a crash.
    if r.returncode not in (0, 3):
        raise RuntimeError(f"{recover} failed for {udid}: {r.stderr.strip()[:200]}")
    return r.stdout


# A refusal is a statement about the DATA, never about the builds. The
# distinction is easy to lose once the JSON is pasted into a triage row: a
# WITNESS-DISPROPORTIONATE on a cluster whose evidence the reader cannot see
# means "this data cannot answer the question", NOT "the baseline never ran the
# path" — opposite meanings, identical output. So the tool says so itself rather
# than relying on whoever reads it to remember.
NOT_A_FINDING = ("this is a statement about the DATA, not about the builds: "
                 "the comparison could not be made, which is not evidence that "
                 "the behaviour is absent on either side")


def fail(reason: str, detail: dict) -> int:
    print(json.dumps({"comparable": False, "reason": reason,
                      "not_a_finding": NOT_A_FINDING, **detail}, indent=2))
    print(f"differential-check: NO COMPARISON EMITTED — {reason}", file=sys.stderr)
    print("  A count from this pair would look like a result and would not be one.", file=sys.stderr)
    print(f"  {NOT_A_FINDING}.", file=sys.stderr)
    return 5


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--candidate-udid", required=True)
    ap.add_argument("--candidate-start", required=True)
    ap.add_argument("--candidate-end", required=True)
    ap.add_argument("--baseline-udid", required=True)
    ap.add_argument("--baseline-start", required=True)
    ap.add_argument("--baseline-end", required=True)
    ap.add_argument("--signature", required=True, help="regex for the thing being counted")
    ap.add_argument("--witness", required=True,
                    help="regex that can only match if the path under test actually ran")
    ap.add_argument("--min-witness", type=int, default=1,
                    help="minimum witness hits required on EACH side. 1 is almost always "
                         "too weak — incidental mentions clear it. Set it to what a genuine "
                         "exercise of the path actually produces.")
    ap.add_argument("--max-witness-ratio", type=float, default=10.0,
                    help="refuse if one side's witness DENSITY (hits per 1000 lines) exceeds "
                         "the other's by more than this factor: the path ran on both sides, "
                         "but not comparably.")
    ap.add_argument("--recover-cmd", default=DEFAULT_RECOVER, help="test seam")
    ap.add_argument("--simctl-json", default=None, help="test seam: device data from a file")
    args = ap.parse_args()

    try:
        cand_dev = device_of(args.candidate_udid, args.simctl_json)
        base_dev = device_of(args.baseline_udid, args.simctl_json)
    except (KeyError, subprocess.CalledProcessError) as exc:
        print(f"differential-check: {exc}", file=sys.stderr)
        return 1

    devices = {"candidate": {"device": cand_dev[2], "device_type": cand_dev[0], "os": cand_dev[1]},
               "baseline": {"device": base_dev[2], "device_type": base_dev[0], "os": base_dev[1]}}

    if cand_dev[0] != base_dev[0]:
        return fail("DEVICE-MISMATCH", devices)
    if cand_dev[1] != base_dev[1]:
        return fail("OS-MISMATCH", devices)

    try:
        cand = read_window(args.recover_cmd, args.candidate_udid, args.candidate_start, args.candidate_end)
        base = read_window(args.recover_cmd, args.baseline_udid, args.baseline_start, args.baseline_end)
    except RuntimeError as exc:
        print(f"differential-check: {exc}", file=sys.stderr)
        return 1

    wrx, srx = re.compile(args.witness), re.compile(args.signature)
    cw, bw = len(wrx.findall(cand)), len(wrx.findall(base))
    cl, bl = max(cand.count("\n"), 1), max(base.count("\n"), 1)
    cd, bd = cw / cl * 1000, bw / bl * 1000
    witness = {"witness_candidate": cw, "witness_baseline": bw,
               "lines_candidate": cl, "lines_baseline": bl,
               "witness_per_kloc_candidate": round(cd, 4),
               "witness_per_kloc_baseline": round(bd, 4),
               **devices}

    # The witness checks are the whole point: a zero signature count on a side
    # that never ran the path is not a negative, and must never be reported as
    # one. Check the BASELINE explicitly even when the candidate is fine — that
    # is the direction that produces a false REGRESSION.
    if cw < args.min_witness:
        return fail("UNEXERCISED-CANDIDATE", witness)
    if bw < args.min_witness:
        return fail("UNEXERCISED-BASELINE", witness)
    # Both sides touched the path, but a handful of incidental hits against a
    # window that is orders of magnitude longer is not the same exercise. Compare
    # density, not raw counts: window lengths are not controlled.
    lo, hi = sorted((cd, bd))
    if lo <= 0 or hi / lo > args.max_witness_ratio:
        return fail("WITNESS-DISPROPORTIONATE", witness)

    cs, bs = len(srx.findall(cand)), len(srx.findall(base))
    print(json.dumps({
        "comparable": True,
        **witness,
        "signature_candidate": cs,
        "signature_baseline": bs,
        # Evidence, not a verdict. A human decides the disposition; this only
        # says the two numbers are of the same kind and may be compared.
        "note": "preconditions held; these counts are comparable",
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
