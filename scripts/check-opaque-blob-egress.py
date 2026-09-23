#!/usr/bin/env python3
"""
check-opaque-blob-egress.py — flag a whole opaque payload being interpolated
into something that leaves the device.

No existing detector in `scripts/` covers data egress. The nearest by name are
`check-pre-ga-crash-triage.py` (triages crash signatures before GA),
`check-foreign-host-401-scoping.py` (auth dispatch scoping) and
`check-discipline-nudge.py` (commit advisories); none reads what is being SENT.
This is a new predicate.

## The defect this catches

Palace reports diagnostics to Crashlytics. Some of what it reasons about arrives
from outside the app — an MDM's managed-configuration dictionary was the first
example and will not be the last. Those payloads belong to the organisation that
sent them, may carry unrelated settings today and sensitive ones tomorrow, and
none of it is ours to forward.

PR #1508 shipped exactly that, in one line:

    detail: "configuration \\(fingerprint) resolved to no library in the loaded registry"

`fingerprint` had been a digest of the PARSED configuration — ours, narrow, safe.
It was changed to a serialisation of the ENTIRE managed dictionary to fix an
unrelated bug, and nothing revisited the consumers. Three lines above it a doc
comment still asserted the detail "Carries configuration keys and library
identifiers only".

A test guarding this existed and passed throughout, because it asserted the
absence of "@", "barcode", "password", "token" and "pin" and no fixture in the
suite ever contained a value we did not own. `PalaceTests/Mocks/ForeignPayloadCanary.swift`
is the test-side answer; this is the side that does not need anyone to remember.

## Why the obvious predicates do not work

Two were measured against this tree before settling on the one below.

"A file that calls a sink" matches 47 production files and 45 test files. A gate
firing on a fifth of the app is a gate people learn to bypass.

"A file that calls a sink AND reads an external payload" matches 9 files — a
workable number, and it MISSES the motivating defect entirely. The read and the
sink were one function call apart across a type boundary: the reporting file
never touched `UserDefaults`, it asked `ManagedAppConfiguration` for a value.
Any file-local dataflow proxy fails on that shape, and that shape is ordinary
once code is decomposed at all.

So this does not trace data. It reads the one thing visible at the sink: the
NAME of what is interpolated. A value called `payload`, `dictionary`,
`fingerprint`, `identity`, `userInfo` or `body` is an opaque blob whose contents
the author has not enumerated. Sending one is either a disclosure or a thing
worth saying out loud.

Narrow on purpose. It will not catch a leak through a well-named variable, and
nothing regex-shaped could — a real taint analyser is the honest alternative and
a tool nobody runs catches nothing. This fires on `git commit`, on the shape
that actually shipped, at a measured zero false positives.

## Calibration (2026-09-23)

  Palace/**/*.swift at HEAD ............ 0 findings
  the defect as shipped (92142e6cf) .... 1 finding, the leaking line

The identifier must END at the blob noun, which is what makes that zero real:
`rawPayload`, `managedDictionary` and `fingerprint` match; `configuredValue`,
`identityProvider` and `bodyText` do not. An earlier, looser form matched
`configuredValue` — the correctly-narrowed replacement for the leak — and so
would have fired on the fix while passing the bug.

## Exit codes

  0  no findings (or --no-block)
  1  findings, blocking
  2  input error
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Names denoting a whole opaque payload rather than a named field. Whoever wrote
# a line interpolating one of these has not said what is inside it, and that is
# the property that makes sending it unsafe.
BLOB_NOUNS = (
    "payload", "dictionary", "dict", "identity", "fingerprint",
    "userInfo", "body", "blob", "contents", "config", "configuration",
)

# `\(someThingPayload)` — the identifier must END at the noun, so a narrower
# value that merely contains the word is not flagged.
INTERPOLATION = re.compile(
    r"\\\(\s*(?:self\.)?\w*(?:" + "|".join(BLOB_NOUNS) + r")\s*\)",
    re.IGNORECASE,
)

# Something that leaves the device, or an argument label destined for one.
EGRESS_CONTEXT = re.compile(
    r"TPPErrorLogger\.log|Crashlytics|Analytics\.logEvent"
    r"|\bsummary:|\bdetail:|\bmetadata:"
)

# How far above the interpolation to look, so a multi-line call still
# associates. Six covers every `TPPErrorLogger.logError(` shape in the tree.
CONTEXT_LINES = 6

SUPPRESSION = "no-opaque-egress:"


class Finding:
    def __init__(self, path: str, line: int, text: str):
        self.path, self.line, self.text = path, line, text

    def __str__(self) -> str:
        return (
            f"{self.path}:{self.line}\n"
            f"    {self.text.strip()}\n"
            f"    An opaque payload is being interpolated into something that leaves the\n"
            f"    device. If its contents are not all ours this is a disclosure: build the\n"
            f"    message from named fields you own instead. If they genuinely are all ours,\n"
            f"    say so with a trailing  // {SUPPRESSION} <reason>"
        )


def scan_text(text: str, path: str) -> list[Finding]:
    findings: list[Finding] = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if SUPPRESSION in line:
            continue
        if not INTERPOLATION.search(line):
            continue
        window = "\n".join(lines[max(0, i - CONTEXT_LINES): i + 3])
        if EGRESS_CONTEXT.search(window):
            findings.append(Finding(path, i + 1, line))
    return findings


def hunks_by_file(diff: str) -> dict[str, list[tuple[str, bool]]]:
    """Per file, the hunk lines as (text, was_added).

    Reconstructed from the diff rather than read from disk. Reading from disk
    was the first implementation and it silently found nothing when the working
    tree had moved past the diff — a gate that cannot fail reports a pass, which
    is the failure it exists to prevent. The hunk carries its own context lines,
    which is all a multi-line call needs to associate.
    """
    out: dict[str, list[tuple[str, bool]]] = {}
    path = None
    for raw in diff.splitlines():
        if raw.startswith("+++ b/"):
            path = raw[6:]
            out.setdefault(path, [])
        elif path is None or raw.startswith(("@@", "---", "diff ", "index ")):
            continue
        elif raw.startswith("+"):
            out[path].append((raw[1:], True))
        elif raw.startswith(" "):
            out[path].append((raw[1:], False))
        # Removed lines contribute no context to the post-change file.
    return out


def is_production_swift(path: str) -> bool:
    return path.endswith(".swift") and "/PalaceTests/" not in f"/{path}"


def scan_diff(diff: str, root: Path = Path(".")) -> list[Finding]:
    """Findings on lines this diff ADDS.

    Diff-scoped: the point is to stop new disclosure, not to open a campaign
    against every file that already exists.
    """
    findings: list[Finding] = []
    for path, lines in hunks_by_file(diff).items():
        if not is_production_swift(path) or not any(added for _, added in lines):
            continue
        text = "\n".join(t for t, _ in lines)
        added_indices = {i + 1 for i, (_, added) in enumerate(lines) if added}
        for f in scan_text(text, path):
            if f.line in added_indices:
                # Report the hunk-relative position; the path plus the source
                # line is what a reader needs, and the hunk is what was judged.
                findings.append(f)
    return findings


def scan_tree(root: str) -> list[Finding]:
    findings: list[Finding] = []
    for p in sorted(Path(root).rglob("*.swift")):
        if not is_production_swift(str(p)):
            continue
        findings.extend(scan_text(p.read_text(errors="ignore"), str(p)))
    return findings


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-opaque-blob-egress.py",
        description="Flag a whole opaque payload interpolated into something "
                    "that leaves the device (Crashlytics, analytics, a report).",
    )
    parser.add_argument("--diff", default=None,
                        help="Unified-diff file, or '-' for stdin. Default mode.")
    parser.add_argument("--scan", default=None,
                        help="Directory to walk instead of a diff (calibration).")
    parser.add_argument("--no-block", action="store_true",
                        help="Print findings, always exit 0.")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress the summary line.")
    args = parser.parse_args(argv)

    try:
        if args.scan:
            findings = scan_tree(args.scan)
        else:
            src = sys.stdin.read() if args.diff in (None, "-") else Path(args.diff).read_text()
            findings = scan_diff(src)
    except OSError as exc:
        print(f"check-opaque-blob-egress: {exc}", file=sys.stderr)
        return 2

    for f in findings:
        print(str(f))
        print()

    if not args.quiet:
        where = args.scan or "the diff"
        print(f"check-opaque-blob-egress: {len(findings)} finding(s) in {where}",
              file=sys.stderr)

    return 1 if findings and not args.no_block else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
