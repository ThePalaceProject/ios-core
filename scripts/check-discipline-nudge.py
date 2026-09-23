#!/usr/bin/env python3
"""
check-discipline-nudge.py — NON-BLOCKING commit-discipline advisories.

Prints gentle nudges (and ALWAYS exits 0 — never fails a commit) on two
retrospective-tracked discipline signals that were trending the wrong way:

  1. Root-cause prose: a `fix`-type commit whose body has no "why it broke"
     line. (Retro: root-cause prose 5.3% of commits, target 30%.)
  2. Test:source: a `fix`/`feat` commit that changes production source with no
     accompanying test file. (Retro: test:source 0.74, target >=0.8.)

It is advisory by design — it surfaces the habit at the moment of commit so the
author can choose to fix it, without ever blocking. Wired into the commit-msg
hook after the M1 gates.

Usage:
  check-discipline-nudge.py --commit-msg <file> [--diff <file|->]
"""
import argparse
import os
import re
import sys

# Words/phrases that count as a root-cause / "why" explanation in a commit body.
_ROOT_CAUSE_RE = re.compile(
    r"\b(because|root[\s-]?cause|caused by|the bug|regression|stems from|"
    r"due to|root of|the issue was|was that|introduced by|culprit|why:)\b",
    re.IGNORECASE,
)
# Subject is a fix / feature (the commit types that warrant tests + root-cause).
_FIX_RE = re.compile(r"^\s*(fix|bugfix|hotfix)\b|\bPP-\d+\b.*\b(fix|crash|regression|bug)\b|^\s*\w+:\s*fix", re.IGNORECASE)
_FEAT_RE = re.compile(r"^\s*(feat|feature)\b", re.IGNORECASE)
_FILE_RE = re.compile(r"^\+\+\+ b/(.+)$")


def _read(path):
    if not path:
        return ""
    if path == "-":
        return "" if sys.stdin.isatty() else sys.stdin.read()
    return open(path, errors="ignore").read() if os.path.exists(path) else ""


def _changed_files(diff_text):
    src, tests = 0, 0
    for line in diff_text.splitlines():
        m = _FILE_RE.match(line)
        if not m:
            continue
        p = m.group(1).strip()
        if p == "/dev/null":
            continue
        low = p.lower()
        if not (low.endswith(".swift") or low.endswith(".m") or low.endswith(".mm")):
            continue
        if "test" in low:  # PalaceTests/…, *Tests.swift, *Test.swift
            tests += 1
        elif p.startswith("Palace/"):
            src += 1
    return src, tests


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit-msg", default=None)
    ap.add_argument("--diff", default="-")
    a = ap.parse_args(argv)

    msg = _read(a.commit_msg)
    diff = _read(a.diff)

    lines = [l for l in msg.splitlines() if not l.startswith("#")]
    subject = next((l for l in lines if l.strip()), "")
    body = "\n".join(lines[1:]) if len(lines) > 1 else ""

    is_fix = bool(_FIX_RE.search(subject))
    is_feat = bool(_FEAT_RE.search(subject))
    src, tests = _changed_files(diff)

    nudges = []
    if is_fix and not _ROOT_CAUSE_RE.search(body):
        nudges.append(
            "fix commit without a root-cause line — add one sentence on WHY it "
            "broke (e.g. \"because …\"). Retro: root-cause prose 5.3%, target 30%.")
    if (is_fix or is_feat) and src > 0 and tests == 0:
        nudges.append(
            f"{src} production source file(s) changed, 0 test files — consider a "
            f"test or note why none. Retro: test:source 0.74, target ≥0.8.")

    if nudges:
        sys.stderr.write("\n\033[33m▲ discipline nudge\033[0m (advisory — NOT blocking; commit proceeds):\n")
        for n in nudges:
            sys.stderr.write(f"  • {n}\n")
        sys.stderr.write("\n")
    return 0  # never block


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
