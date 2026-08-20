#!/usr/bin/env python3
"""
check-chaos-cause-discipline.py — keep a chaos finding's OBSERVATION separate
from its CAUSE.

A chaos-qa row carries `Verified: true`, which the agent contract scopes to the
OBSERVATION ("you witnessed it, with log evidence"). Nothing scoped the CAUSE.
So an agent could back its observation with a log line and then assert a
mechanism for free, in the `Title`, under a verified flag — and downstream
triage reads the whole row as verified.

Observed in rc-3.3.0-20260820: of 15 root-cause clusters, three had a sound
observation and a wrong stated cause.
  - a "malformed double-slash URL" that returns HTTP 200 and a valid JPEG
  - "duplicate return calls" supported by a single log line (one error, one tap)
  - a "removed in-flight guard" that was never removed (unchanged since 3.0.0)
Each cost a triage cycle to disprove, and one nearly dispatched a fix for a
defect that did not exist.

THE BLOCKING RULE IS STRUCTURAL, NEVER LINGUISTIC. Every finding must declare a
`Cause Status`; the gate never fails a row over its wording. Prose heuristics
are advisory (CHAOS-CAUSE-ADVISORY) so this gate cannot false-positive on
phrasing — a linguistic gate would be exactly the kind of unverifiable
judgement this detector exists to stamp out.

Legal `Cause Status` values:
    none                 no mechanism is being claimed (observation only)
    unverified           a mechanism is suspected but NOT established
    verified:<artifact>  established, and <artifact> is the proof on disk

Checks (all fatal unless noted):
  C0  row width does not match the header (shifted/lost fields)
  C1  finding has no `Cause Status`
  C2  `Cause Status` is not one of the legal values
  C3  `verified:<artifact>` names an artifact that does not exist
  C4  `Suspected Cause` is populated while `Cause Status` says `none`
  ADVISORY  `Title` asserts an internal mechanism while the cause is unverified
  ADVISORY  prose quotes a measurement while a replay YAML that could settle
            it is attached to the same finding

Output (greppable):
  CHAOS-CAUSE: <file>:<row>: [C<n>] <message>
  CHAOS-CAUSE-ADVISORY: <file>:<row>: <message>
  CHAOS-CAUSE: <file>: LEGACY schema — no `Cause Status` column

Usage:
  python3 scripts/check-chaos-cause-discipline.py [--strict] [--quiet] CSV [CSV ...]

Flags:
  --strict   Treat a legacy header (missing the columns) as a failure. The
             chaos runner passes this: a NEW run must emit the columns.
             Without it, pre-existing corpora are reported and pass.
  --quiet    Suppress the trailing summary line.

Exit: 0 clean · 1 violations · 2 usage error
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass
from pathlib import Path

CAUSE_STATUS = "Cause Status"
SUSPECTED_CAUSE = "Suspected Cause"
TITLE = "Title"

_VERIFIED_PREFIX = "verified:"
_LEGAL_BARE = {"none", "unverified"}

# Words that name internal state a simulator observer CANNOT see. Advisory
# only: seeing one of these in a headline means the row is describing a
# mechanism, which is fine — provided the cause is actually backed.
_MECHANISM_RE = re.compile(
    r"\b("
    r"duplicate|duplicated|race|deadlock|leak(?:s|ed|ing)?|retain cycle|"
    r"debounce|deduped?|not deduped|guard|regression caused|"
    r"because|due to|caused by|results? in|leads? to|malformed|"
    r"double[- ]free|off[- ]by[- ]one|stale cache|missing await"
    r")\b",
    re.IGNORECASE,
)


# A measurement stated in prose, where a machine-readable artifact that could
# settle it sits in the same run dir. rc-3.3.0: a finding's notes said the taps
# landed "in <300ms"; the replay's own captured_at stamps showed ~1.6s gaps over
# 6.4s. The wrong number survived into two hypotheses and a dispatch before
# anyone opened the YAML.
_PROSE_TIMING_RE = re.compile(
    r"[<>~]?\s*\d+(?:\.\d+)?\s*(?:ms|milliseconds?|s\b|sec|secs|seconds?)",
    re.IGNORECASE,
)
_REPLAY_REF_RE = re.compile(r"replay\s*=\s*\S+", re.IGNORECASE)


@dataclass(frozen=True)
class Violation:
    path: str
    row_no: int
    code: str
    message: str
    advisory: bool = False

    def render(self) -> str:
        tag = "CHAOS-CAUSE-ADVISORY" if self.advisory else "CHAOS-CAUSE"
        code = "" if self.advisory else f"[{self.code}] "
        return f"{tag}: {self.path}:{self.row_no}: {code}{self.message}"


def _check_row(path: str, row_no: int, row: dict) -> list[Violation]:
    title = (row.get(TITLE) or "").strip()
    if not title:
        # Blank-title rows are header padding / partial writes, not findings.
        return []

    status = (row.get(CAUSE_STATUS) or "").strip()
    cause = (row.get(SUSPECTED_CAUSE) or "").strip()
    out: list[Violation] = []

    if not status:
        out.append(Violation(
            path, row_no, "C1",
            "no `Cause Status`. Every finding must declare one of "
            "none | unverified | verified:<artifact>. If you are only "
            "reporting what you saw, that is `none` — say so explicitly.",
        ))
        return out

    verified_ok = False
    if status.startswith(_VERIFIED_PREFIX):
        artifact = status[len(_VERIFIED_PREFIX):].strip()
        if not artifact:
            out.append(Violation(
                path, row_no, "C3",
                "`verified:` with no artifact path. Name the file that proves "
                "the cause.",
            ))
        elif not Path(artifact).exists():
            out.append(Violation(
                path, row_no, "C3",
                f"`verified:` names a missing artifact: {artifact}. A cause is "
                "verified by an artifact on disk, not by confidence.",
            ))
        else:
            verified_ok = True
    elif status not in _LEGAL_BARE:
        out.append(Violation(
            path, row_no, "C2",
            f"illegal `Cause Status` {status!r}. Legal: none | unverified | "
            "verified:<artifact>.",
        ))

    if cause and status == "none":
        out.append(Violation(
            path, row_no, "C4",
            "`Suspected Cause` is populated but `Cause Status` says `none`. "
            "If you name a mechanism, its status is `unverified` until an "
            "artifact backs it.",
        ))

    prose = " ".join(
        (row.get(k) or "") for k in ("Notes", "Steps", "Candidate Behavior")
    )
    if _REPLAY_REF_RE.search(prose):
        t = _PROSE_TIMING_RE.search(prose)
        if t:
            out.append(Violation(
                path, row_no, "ADV",
                f"prose states a measurement ({t.group(0).strip()!r}) and a "
                "replay YAML is attached. The replay's captured_at stamps are "
                "ground truth — read them rather than quoting the prose.",
                advisory=True,
            ))

    if not verified_ok:
        hit = _MECHANISM_RE.search(title)
        if hit:
            out.append(Violation(
                path, row_no, "ADV",
                f"`Title` asserts a mechanism ({hit.group(0)!r}) while the "
                "cause is not verified. Titles should state the OBSERVABLE; "
                "move the mechanism to `Suspected Cause`.",
                advisory=True,
            ))

    return out


def _check_file(path: Path, strict: bool) -> tuple[list[Violation], bool]:
    """Return (violations, legacy). `legacy` means the schema predates the columns."""
    with path.open(newline="") as f:
        rows = list(csv.reader(f))
    if not rows:
        return ([], False)

    header = rows[0]
    legacy = CAUSE_STATUS not in header
    if legacy:
        print(f"CHAOS-CAUSE: {path}: LEGACY schema — no `{CAUSE_STATUS}` "
              f"column; cause discipline unenforceable on this file.")

    violations: list[Violation] = []
    # row_no is 1-based over DATA rows, matching how a reader counts findings.
    for i, raw in enumerate(rows[1:], start=1):
        # C0 FIRST. csv.DictReader does not raise on a width mismatch: extra
        # fields vanish into restkey and every named column past the break is
        # shifted, so a corrupt row can present a legal `Cause Status` it never
        # declared. Once the shape is wrong, no field reading from this row is
        # trustworthy — so C0 replaces the field checks rather than joining
        # them. Emitting a confident C2 about a shifted value would be the
        # exact sin this detector exists to prevent.
        if len(raw) != len(header):
            if any(cell.strip() for cell in raw):
                violations.append(Violation(
                    str(path), i, "C0",
                    f"row has {len(raw)} fields but the header declares "
                    f"{len(header)}. Almost always an unquoted comma inside a "
                    "prose column; every field after the break is shifted and "
                    "the overflow is silently discarded. Quote the field.",
                ))
            continue
        if legacy:
            # No `Cause Status` column exists to judge, so the field checks
            # would fire on every row. C0 above is still meaningful: it is pure
            # structure and needs no schema.
            continue
        violations.extend(_check_row(str(path), i, dict(zip(header, raw))))

    return (violations, legacy)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("csvs", nargs="+", help="chaos findings CSV path(s)")
    ap.add_argument("--strict", action="store_true",
                    help="fail on a legacy header (a new run must emit the columns)")
    ap.add_argument("--quiet", action="store_true", help="suppress the summary line")
    args = ap.parse_args(argv)

    paths: list[Path] = []
    for raw in args.csvs:
        p = Path(raw)
        if not p.is_file():
            print(f"ERROR: not a file: {p}", file=sys.stderr)
            return 2
        paths.append(p)

    all_violations: list[Violation] = []
    legacy_violations: list[Violation] = []
    legacy_files = 0
    for p in paths:
        violations, legacy = _check_file(p, args.strict)
        legacy_files += int(legacy)
        all_violations.extend(violations)
        if legacy:
            legacy_violations.extend(violations)

    for v in all_violations:
        print(v.render())

    # A legacy file is unenforceable by declaration; its C0s are surfaced but
    # only bite under --strict, exactly as the legacy header itself does.
    # Otherwise adding this check would retroactively fail historical corpora.
    fatal = [v for v in all_violations
             if not v.advisory and v not in legacy_violations]
    advisory = [v for v in all_violations if v.advisory]

    if not args.quiet:
        bits = [f"{len(fatal)} cause-discipline violation(s)"]
        if advisory:
            bits.append(f"{len(advisory)} advisory")
        if legacy_files:
            bits.append(f"{legacy_files} legacy file(s)")
        print("\n" + ", ".join(bits) + f" across {len(paths)} file(s).",
              file=sys.stderr)

    if fatal:
        return 1
    if legacy_files and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
