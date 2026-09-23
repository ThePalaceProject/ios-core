#!/usr/bin/env python3
"""
test_ledger_scc.py — self-verify the ledger SCC collapser
(scripts/ledger_scc.py).

Two defects motivated the script and are pinned here as regressions:

  1. `.github/workflows/ledger.yml` extracted cycle detail with
     `jq '.cycles[] | .components'`, but CodeAtlas Ledger emits `.cycles` as an
     INTEGER and puts the detail in `.issues[]`. The jq errored into
     /dev/null and every PR comment silently fell through to "See full report
     for cycle details." `analysis-real-develop.json` is a byte-for-byte
     capture of real `ledger observe --domains arch` output so the shape that
     broke the jq is what the tests run against.

  2. The reported cycle count enumerates cycle PATHS, not distinct cycles. The
     real capture reports 36 "cycles" that are 2 strongly-connected components
     (one of 17 nodes, one of 2). Path count in a dense SCC is combinatorial:
     a single added edge swings it by ~10 with no architectural change, which
     is why the number ranged 10..29 across a month of PRs while the
     underlying graph held steady.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "ledger_scc.py"
_FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "ledger_scc"
_REAL = _FIXTURE_DIR / "analysis-real-develop.json"


def _run(analysis: Path, config: Path | None = None, extra: list[str] | None = None):
    cmd = [sys.executable, str(_SCRIPT), "--analysis", str(analysis)]
    if config is not None:
        cmd += ["--config", str(config)]
    cmd += extra or []
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def _summary(tmp_path: Path, analysis: Path, config: Path | None = None) -> dict:
    out = tmp_path / "scc.json"
    rc, _, err = _run(analysis, config, ["--json", str(out)])
    assert rc == 0, f"exit {rc}: {err}"
    return json.loads(out.read_text())


def _write(tmp_path: Path, name: str, cycles: list[str], **extra) -> Path:
    """Build an analysis.json in the real emitted shape."""
    issues = [
        {
            "components": sorted({c.strip() for c in path.split("→")}),
            "description": f"Dependency cycle detected: {path}",
            "severity": "high",
            "type": "dependency_cycle",
        }
        for path in cycles
    ]
    doc = {
        "averageCoupling": 4.86,
        "components": 42,
        # NOTE: an integer, exactly as ledger emits it. This is defect #1.
        "cycles": len(cycles),
        "dependencies": 204,
        "findings": [],
        "hotspots": 12,
        "issues": issues,
        "violations": 1,
    }
    doc.update(extra)
    p = tmp_path / name
    p.write_text(json.dumps(doc, indent=2))
    return p


# ───────────────────────────── defect #1: the shape ─────────────────────────

def test_realCapture_cyclesField_isIntegerNotArray():
    """The jq that broke was `.cycles[]`. Pin the shape that makes it break."""
    doc = json.loads(_REAL.read_text())
    assert isinstance(doc["cycles"], int)
    assert doc["findings"] == [], "detail is NOT in .findings — that jq was broken too"
    assert any(i["type"] == "dependency_cycle" for i in doc["issues"])


def test_realCapture_producesNonEmptyDetail(tmp_path):
    """The whole point: a PR comment that can actually name the cycles."""
    md = tmp_path / "cycles.md"
    rc, _, err = _run(_REAL, None, ["--markdown", str(md)])
    assert rc == 0, err
    body = md.read_text()
    assert body.strip(), "empty detail is the bug we are fixing"
    assert "Accounts" in body and "MyBooks" in body


# ──────────────────── defect #2: paths collapse to components ────────────────

def test_realCapture_36pathsCollapseTo2components(tmp_path):
    s = _summary(tmp_path, _REAL)
    assert s["cyclePathCount"] == 36
    assert s["sccCount"] == 2
    assert s["largestSccSize"] == 17


def test_manyPathsThroughOneTangle_countAsOneCycle(tmp_path):
    """Five different walks over the same 3 mutually-reachable components."""
    a = _write(tmp_path, "one.json", [
        "A → B → A",
        "A → B → C → A",
        "B → C → B",
        "A → C → A",
        "C → B → A → C",
    ])
    s = _summary(tmp_path, a)
    assert s["cyclePathCount"] == 5
    assert s["sccCount"] == 1
    assert s["largestSccSize"] == 3
    assert s["sccs"][0]["components"] == ["A", "B", "C"]


def test_disjointTangles_countSeparately(tmp_path):
    a = _write(tmp_path, "two.json", ["A → B → A", "Y → Z → Y"])
    s = _summary(tmp_path, a)
    assert s["sccCount"] == 2
    assert s["largestSccSize"] == 2


def test_addingOneEdge_movesPathCountButNotComponentCount(tmp_path):
    """
    The instability claim, made mechanical: one extra edge inside the tangle
    multiplies the reported path count while the SCC reading holds at 1.
    """
    before = _write(tmp_path, "b.json", ["A → B → C → A"])
    after = _write(tmp_path, "a.json", [
        "A → B → C → A", "A → C → A", "A → B → A", "B → C → B",
    ])
    sb, sa = _summary(tmp_path, before), _summary(tmp_path, after)
    assert sa["cyclePathCount"] > sb["cyclePathCount"]
    assert sb["sccCount"] == sa["sccCount"] == 1
    assert sb["largestSccSize"] == sa["largestSccSize"] == 3


def test_noCycles_reportsZeroAndSaysSo(tmp_path):
    a = _write(tmp_path, "clean.json", [])
    s = _summary(tmp_path, a)
    assert s["sccCount"] == 0
    assert s["largestSccSize"] == 0
    md = tmp_path / "m.md"
    rc, _, _ = _run(a, None, ["--markdown", str(md)])
    assert rc == 0
    assert "No dependency cycles" in md.read_text()


def test_selfLoop_isACycle(tmp_path):
    a = _write(tmp_path, "self.json", ["A → A"])
    s = _summary(tmp_path, a)
    assert s["sccCount"] == 1
    assert s["largestSccSize"] == 1


# ─────────────────── knownFalsePositiveEdges are discounted ──────────────────

def _config(tmp_path: Path, edges: list[dict]) -> Path:
    p = tmp_path / "ledger-config.json"
    p.write_text(json.dumps({"knownFalsePositiveEdges": edges}))
    return p


def test_knownFalsePositiveEdge_dissolvesItsCycle(tmp_path):
    a = _write(tmp_path, "fp.json", ["A → B → A", "TriageBotUI → Palace → TriageBotUI"])
    cfg = _config(tmp_path, [{
        "from": "PalaceTriageBot", "aka": "TriageBotUI", "to": "Palace",
        "confidence": "name-inferred",
        "reason": "SwiftPM forbids a package importing the app target.",
    }])
    assert _summary(tmp_path, a)["sccCount"] == 2
    s = _summary(tmp_path, a, cfg)
    assert s["sccCount"] == 1, "the impossible edge must not inflate the count"
    assert s["discountedEdges"] == [{"from": "TriageBotUI", "to": "Palace"}]


def test_realCapture_withRepoConfig_dropsTheImpossibleEdge(tmp_path):
    """`tools/ledger/ledger-config.json` already declares this edge impossible."""
    cfg = _REPO_ROOT / "tools" / "ledger" / "ledger-config.json"
    s = _summary(tmp_path, _REAL, cfg)
    assert s["sccCount"] == 1
    assert s["largestSccSize"] == 17
    assert {"from": "TriageBotUI", "to": "Palace"} in s["discountedEdges"]


def test_discountingIsNotUnconditional(tmp_path):
    """An edge NOT in the config must survive — the discount is a whitelist."""
    a = _write(tmp_path, "keep.json", ["X → Y → X"])
    cfg = _config(tmp_path, [{"from": "TriageBotUI", "to": "Palace"}])
    s = _summary(tmp_path, a, cfg)
    assert s["sccCount"] == 1
    assert s["discountedEdges"] == []


# ───────────────────────────────── robustness ────────────────────────────────

def test_missingAnalysisFile_failsLoudly(tmp_path):
    rc, _, err = _run(tmp_path / "nope.json")
    assert rc != 0
    assert "not found" in err.lower()


def test_unparseableDescription_fallsBackToComponents(tmp_path):
    a = tmp_path / "odd.json"
    a.write_text(json.dumps({
        "cycles": 1, "components": 3, "dependencies": 3, "findings": [],
        "hotspots": 0, "violations": 0,
        "issues": [{
            "components": ["A", "B"],
            "description": "Dependency cycle detected (format changed upstream)",
            "severity": "high", "type": "dependency_cycle",
        }],
    }))
    s = _summary(tmp_path, a)
    assert s["sccCount"] == 1
    assert s["unparsedPaths"] == 1


def test_nonCycleIssues_areIgnored(tmp_path):
    a = _write(tmp_path, "mixed.json", ["A → B → A"])
    doc = json.loads(a.read_text())
    doc["issues"].append({
        "components": ["Catalog"], "description": "Catalog has no dependencies",
        "severity": "low", "type": "orphan_component",
    })
    a.write_text(json.dumps(doc))
    s = _summary(tmp_path, a)
    assert s["sccCount"] == 1
    assert s["largestSccSize"] == 2


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
