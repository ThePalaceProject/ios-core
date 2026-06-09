#!/usr/bin/env python3
"""
Unit tests for post-mutation-pr-comment.py rendering.

Pure-logic tests only — no gh, no subprocess, no network. Feeds synthetic
report dicts (written to a tmp reports dir) through load_reports + render_table
and asserts on the markdown body. Runs in well under 5s.

Run: python3 -m unittest scripts.test_post_mutation_pr_comment
  or: python3 scripts/test_post_mutation_pr_comment.py
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# The script has a hyphenated filename, so import it via importlib rather than
# a normal `import` statement.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "post_mutation_pr_comment",
    os.path.join(_HERE, "post-mutation-pr-comment.py"),
)
pmpc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(pmpc)


def _write_report(d: Path, slug: str, report: dict) -> None:
    (d / f"{slug}.json").write_text(json.dumps(report))


def _modern_report(*, file, killed, survived, critical=False,
                   cp_survivors=0, uncovered=0, suppressed=0,
                   coverage_gap=None, results=None):
    return {
        "file": file,
        "tests": ["PalaceTests/Foo"],
        "seed": 1,
        "summary": {
            "killed": killed,
            "survived": survived,
            "errored": 0,
            "kill_rate_pct": round(killed / (killed + survived) * 100, 1)
            if (killed + survived) else 0.0,
            "partial": False,
            "completed_mutations": killed + survived,
            "planned_mutations": killed + survived,
            "uncovered": uncovered,
            "suppressed": suppressed,
            "is_critical_path": critical,
            "critical_path_survivors": cp_survivors,
        },
        "coverage_gap": coverage_gap or [],
        "results": results or [],
    }


class CriticalPathSurvivorBlocks(unittest.TestCase):

    def test_survivorOnCriticalPath_blocksEvenAt100PercentKillRate(self):
        # 10 killed, 0 survived => 100% kill rate, but a consequential survivor
        # is recorded separately. The render must BLOCK, not PASS.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_report(d, "audiobk", _modern_report(
                file="Palace/Audiobooks/AudiobookSessionManager.swift",
                killed=10, survived=0, critical=True, cp_survivors=2,
            ))
            rows = pmpc.load_reports(d)
            body = pmpc.render_table(rows, threshold=50.0)

        self.assertIn("BLOCKS MERGE", body,
                      "critical-path survivor must produce a blocking banner")
        self.assertIn("regardless of kill rate", body)
        # The per-row verdict must not say PASS for this file.
        self.assertNotIn("PASS (critical)", body)
        # fail-on-critical equivalent: the loader row carries the count.
        self.assertEqual(rows[0]["critical_path_survivors"], 2)

    def test_noSurvivors_highKillRate_doesNotBlock(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_report(d, "audiobk", _modern_report(
                file="Palace/Audiobooks/AudiobookSessionManager.swift",
                killed=10, survived=0, critical=True, cp_survivors=0,
            ))
            rows = pmpc.load_reports(d)
            body = pmpc.render_table(rows, threshold=50.0)
        self.assertNotIn("BLOCKS MERGE", body)
        self.assertIn("PASS (critical)", body)


class CoverageGapCallout(unittest.TestCase):

    def test_uncoveredLines_renderAsCoverageGapTodo(self):
        gap = [{"line": 42, "op": "cmp"}, {"line": 88, "op": "bool"}]
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_report(d, "f", _modern_report(
                file="Palace/Foo/Bar.swift",
                killed=3, survived=1, uncovered=2, coverage_gap=gap,
            ))
            rows = pmpc.load_reports(d)
            body = pmpc.render_table(rows, threshold=50.0)
        self.assertIn("Coverage gap", body)
        self.assertIn("42", body)
        self.assertIn("88", body)
        self.assertIn("`cmp`", body)
        # Coverage gap is NON-blocking — it's a to-do callout, not a fail.
        self.assertIn("free coverage to-do", body)
        self.assertNotIn("BLOCKS MERGE", body)


class SuppressedCallout(unittest.TestCase):

    def test_suppressedMutants_surfacedAsInformational(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_report(d, "f", _modern_report(
                file="Palace/Foo/Bar.swift",
                killed=4, survived=0, suppressed=3,
            ))
            rows = pmpc.load_reports(d)
            body = pmpc.render_table(rows, threshold=50.0)
        self.assertIn("3 mutant(s) suppressed", body)
        self.assertIn("not counted against the", body)


class BackwardCompatMissingKeys(unittest.TestCase):

    def test_oldReportWithoutNewKeys_rendersWithoutError(self):
        # An older cached report: summary has ONLY the original keys.
        old = {
            "file": "Palace/Legacy/Old.swift",
            "summary": {
                "killed": 2,
                "survived": 2,
                "errored": 0,
                "kill_rate_pct": 50.0,
            },
        }
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_report(d, "old", old)
            rows = pmpc.load_reports(d)
            body = pmpc.render_table(rows, threshold=50.0)
        # No KeyError, no crash; defaults applied.
        self.assertEqual(rows[0]["critical_path_survivors"], 0)
        self.assertEqual(rows[0]["uncovered"], 0)
        self.assertEqual(rows[0]["suppressed"], 0)
        self.assertEqual(rows[0]["coverage_gap"], [])
        self.assertNotIn("BLOCKS MERGE", body)
        self.assertNotIn("Coverage gap", body)
        self.assertIn("Old.swift", body)

    def test_isCriticalPathFlag_overridesPrefixHeuristic(self):
        # File path is NOT under a critical prefix, but the report flags it.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_report(d, "f", _modern_report(
                file="Palace/Accounts/Library/AccountsManager.swift",
                killed=1, survived=1, critical=True, cp_survivors=0,
            ))
            rows = pmpc.load_reports(d)
        self.assertTrue(rows[0]["critical"],
                        "report's is_critical_path flag must win over the "
                        "local prefix heuristic")


class FooterPriority(unittest.TestCase):

    def test_criticalSurvivorAndLowKillRate_survivorBannerWinsFooter(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            # Critical file: low kill rate AND a survivor — survivor block wins.
            _write_report(d, "a", _modern_report(
                file="Palace/SignInLogic/TPPSignInBusinessLogic.swift",
                killed=1, survived=4, critical=True, cp_survivors=1,
            ))
            rows = pmpc.load_reports(d)
            body = pmpc.render_table(rows, threshold=50.0)
        footer = body.rsplit("\n", 6)[-1] if "\n" in body else body
        self.assertIn("surviving", body)
        self.assertIn("gate blocks merge", body)


if __name__ == "__main__":
    unittest.main()
