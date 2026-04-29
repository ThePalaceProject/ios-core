#!/usr/bin/env python3
"""
a11y-coverage.py — measure VoiceOver label coverage against a simdrive fixture.

For a given fixture (.specterqa/fixtures/baselines/<version>/<flow>/<step>.json),
compare the on-screen text marks (what the user SEES) against the iOS accessibility
tree (what VoiceOver READS). Anything visible-but-unlabeled is a VoiceOver gap.

Usage
-----
    # Full coverage report for one fixture:
    a11y-coverage.py --fixture .specterqa/fixtures/baselines/3.0.0/anonymous-borrow/03-catalog.json \\
                     --udid F3CB599D-B154-4D40-B2C4-52F821EABAD7

    # CI mode — fail if coverage drops below threshold:
    a11y-coverage.py --fixture <path> --udid <udid> --min-coverage 0.85 --json /tmp/a11y.json

    # Re-use a previously captured ax dump (skip live sim hit):
    a11y-coverage.py --fixture <path> --ax-dump /tmp/ax.json

Why this exists
---------------
PP-4029 (VoiceOver focus jump after search results) shipped because the bug
lived in how WHAT-IS-RENDERED diverges from WHAT-IS-LABELED. ViewModel tests
can't see either. simdrive's marks are "visible to a sighted user"; the AX
dump is "visible to VoiceOver." Coverage % = labeled / visible.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable


# ---------- data ----------

@dataclass
class FixtureMark:
    id: int
    bbox: list[int]   # [x, y, w, h]
    center: list[int] # [x, y]
    text: str
    confidence: float


@dataclass
class AxNode:
    label: str
    role: str | None
    frame: list[int] | None  # [x, y, w, h] in pixels (best-effort)


@dataclass
class CoverageReport:
    fixture: str
    version: str
    visible_marks: int
    visible_unique_labels: int
    labeled_count: int
    unlabeled_count: int
    coverage_ratio: float
    unlabeled: list[str]
    confidence_threshold: float

    def passes(self, min_coverage: float) -> bool:
        return self.coverage_ratio >= min_coverage


# ---------- normalization ----------

_PUNCT_RE = re.compile(r"[\s\W_]+", re.UNICODE)


def normalize(text: str) -> str:
    """Lowercase + strip diacritics + collapse whitespace/punctuation.
    OCR is noisy; AX labels are clean. We compare on a tolerant key.
    """
    nf = unicodedata.normalize("NFKD", text)
    no_diacritic = "".join(ch for ch in nf if not unicodedata.combining(ch))
    collapsed = _PUNCT_RE.sub("", no_diacritic).lower()
    return collapsed


def is_meaningful(text: str) -> bool:
    """Filter out OCR garbage + status-bar noise we don't expect AX to label."""
    n = normalize(text)
    if len(n) < 2:
        return False
    # status-bar timestamps and signal indicators
    if re.fullmatch(r"\d{1,2}\d{2}", n):  # "1255", "118"
        return True  # actually keep — clock IS labeled
    if re.fullmatch(r"\.+", n):
        return False  # signal-strength dots
    return True


# ---------- fixture loading ----------

def load_fixture(path: Path) -> tuple[dict, list[FixtureMark]]:
    raw = json.loads(path.read_text())
    marks = [FixtureMark(**m) for m in raw["marks"]]
    return raw, marks


# ---------- AX dump ----------

def capture_ax_dump(udid: str) -> list[AxNode]:
    """Use `xcrun simctl ui <udid> ax dump` to get the accessibility tree.

    The CLI output format varies by Xcode version; we tolerate both the
    JSON-style and the indented-text style. If neither parses, we return an
    empty list and let the caller report low coverage.
    """
    if not shutil.which("xcrun"):
        raise RuntimeError("xcrun not found — Xcode CLT required for live AX dump")

    # Newer Xcode: `simctl ui <udid> appearance` etc. The exact subcommand for
    # ax dump differs. Try the documented one first, fall back to alternatives.
    candidates = [
        ["xcrun", "simctl", "ui", udid, "ax", "dump"],
        ["xcrun", "simctl", "io", udid, "ax", "dump"],
        ["xcrun", "simctl", "ax", "dump", udid],
    ]
    last_err = None
    for cmd in candidates:
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if out.returncode == 0 and out.stdout.strip():
                return parse_ax_dump(out.stdout)
            last_err = out.stderr.strip() or out.stdout.strip()
        except subprocess.TimeoutExpired as e:
            last_err = f"timeout: {e}"
        except FileNotFoundError as e:
            last_err = str(e)
    raise RuntimeError(
        f"xcrun simctl ax dump failed on every known invocation. Last error: {last_err}\n"
        "Workaround: capture with Xcode's Accessibility Inspector → File → Save As JSON, "
        "then pass --ax-dump <path>."
    )


def parse_ax_dump(text: str) -> list[AxNode]:
    """Parse either JSON-style or indented-text AX dump output."""
    text = text.strip()
    nodes: list[AxNode] = []
    # JSON-style (newer Xcodes)
    if text.startswith("{") or text.startswith("["):
        try:
            data = json.loads(text)
            for n in walk_json_ax(data):
                nodes.append(n)
            return nodes
        except json.JSONDecodeError:
            pass
    # Indented-text style: lines like '  Label: "Borrow", Role: button, Frame: {{x, y}, {w, h}}'
    label_re = re.compile(r'(?:Label|label|AXLabel)[\s:=]+"([^"]*)"')
    role_re = re.compile(r'(?:Role|role|AXRole)[\s:=]+([A-Za-z]+)')
    frame_re = re.compile(r'\{\{(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\}\s*,\s*\{(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\}\}')
    for line in text.splitlines():
        m_label = label_re.search(line)
        if not m_label:
            continue
        label = m_label.group(1)
        role = role_re.search(line)
        frame = frame_re.search(line)
        nodes.append(AxNode(
            label=label,
            role=role.group(1) if role else None,
            frame=[int(float(frame.group(i))) for i in (1, 2, 3, 4)] if frame else None,
        ))
    return nodes


def walk_json_ax(node, parent_role=None) -> Iterable[AxNode]:
    if isinstance(node, list):
        for child in node:
            yield from walk_json_ax(child, parent_role)
        return
    if not isinstance(node, dict):
        return
    label = node.get("label") or node.get("AXLabel") or node.get("name") or ""
    role = node.get("role") or node.get("AXRole") or parent_role
    frame = node.get("frame") or node.get("AXFrame")
    if isinstance(frame, dict):
        frame_list = [int(frame.get("x", 0)), int(frame.get("y", 0)),
                      int(frame.get("width", 0)), int(frame.get("height", 0))]
    elif isinstance(frame, list) and len(frame) == 4:
        frame_list = [int(v) for v in frame]
    else:
        frame_list = None
    if label:
        yield AxNode(label=str(label), role=role, frame=frame_list)
    for k in ("children", "AXChildren", "subviews"):
        if k in node:
            yield from walk_json_ax(node[k], role)


# ---------- coverage ----------

def compute_coverage(
    fixture_meta: dict,
    marks: list[FixtureMark],
    ax_nodes: list[AxNode],
    min_confidence: float = 0.7,
) -> CoverageReport:
    visible: list[FixtureMark] = [
        m for m in marks
        if m.confidence >= min_confidence and is_meaningful(m.text)
    ]
    visible_keys = {normalize(m.text): m.text for m in visible}
    ax_keys = {normalize(n.label) for n in ax_nodes if n.label}

    labeled: list[str] = []
    unlabeled: list[str] = []
    for key, original in visible_keys.items():
        if any(key in ax_key or ax_key in key for ax_key in ax_keys if ax_key):
            labeled.append(original)
        else:
            unlabeled.append(original)

    total = len(visible_keys)
    coverage_ratio = (len(labeled) / total) if total else 1.0

    return CoverageReport(
        fixture=fixture_meta.get("fixture", "<unknown>"),
        version=fixture_meta.get("version", "<unknown>"),
        visible_marks=len(visible),
        visible_unique_labels=total,
        labeled_count=len(labeled),
        unlabeled_count=len(unlabeled),
        coverage_ratio=coverage_ratio,
        unlabeled=sorted(unlabeled),
        confidence_threshold=min_confidence,
    )


# ---------- CLI ----------

def main() -> int:
    p = argparse.ArgumentParser(description="Measure VoiceOver label coverage against a simdrive fixture.")
    p.add_argument("--fixture", required=True, type=Path, help="Path to a fixture .json file.")
    p.add_argument("--udid", help="Simulator UDID for live AX dump (alternative: --ax-dump).")
    p.add_argument("--ax-dump", type=Path, help="Pre-captured AX dump file.")
    p.add_argument("--min-coverage", type=float, default=0.0, help="Fail if coverage_ratio is below this.")
    p.add_argument("--min-confidence", type=float, default=0.7, help="Drop marks with OCR confidence below this.")
    p.add_argument("--json", type=Path, help="Write the full report as JSON to this path.")
    args = p.parse_args()

    if not args.fixture.exists():
        print(f"error: fixture not found: {args.fixture}", file=sys.stderr)
        return 2
    fixture_meta, marks = load_fixture(args.fixture)

    if args.ax_dump:
        ax_nodes = parse_ax_dump(args.ax_dump.read_text())
    elif args.udid:
        ax_nodes = capture_ax_dump(args.udid)
    else:
        print("error: provide --udid or --ax-dump", file=sys.stderr)
        return 2

    report = compute_coverage(fixture_meta, marks, ax_nodes, min_confidence=args.min_confidence)

    print(f"A11y coverage for {report.fixture} ({report.version})")
    print(f"  Visible marks (confidence ≥ {report.confidence_threshold}): {report.visible_marks}")
    print(f"  Unique visible labels:                                       {report.visible_unique_labels}")
    print(f"  Labeled in AX tree:                                          {report.labeled_count}")
    print(f"  Unlabeled (visible but invisible to VoiceOver):              {report.unlabeled_count}")
    print(f"  Coverage ratio:                                              {report.coverage_ratio:.1%}")
    if report.unlabeled:
        print()
        print("  Unlabeled visible text:")
        for u in report.unlabeled:
            print(f"    - {u!r}")

    if args.json:
        args.json.write_text(json.dumps(asdict(report), indent=2, ensure_ascii=False))
        print(f"\nReport: {args.json}")

    if args.min_coverage > 0 and not report.passes(args.min_coverage):
        print(
            f"\nFAIL: coverage {report.coverage_ratio:.1%} < required {args.min_coverage:.1%}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
