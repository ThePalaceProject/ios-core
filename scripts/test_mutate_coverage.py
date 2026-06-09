#!/usr/bin/env python3
"""
Unit tests for mutate_coverage.py helpers.

All tests are PURE Python: no xcodebuild, no simulator, no real .xcresult. The
coverage PARSER is fed synthetic fixtures whose JSON shape matches the real
`xcrun xccov view --archive --file ... --json` output captured from an Xcode 26
bundle on this host (dict keyed by recorded path → list of
{isExecutable, line, executionCount?} entries; covered := isExecutable AND
executionCount > 0).

Run: python3 -m unittest scripts.test_mutate_coverage
  or: python3 scripts/test_mutate_coverage.py
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mutate_coverage as mc


# --- realistic archive JSON fixture (shape matches captured Xcode 26 output) ---
def _archive_json(path, entries):
    """Build an archive-JSON string: { "<path>": [ {entry}, ... ] }."""
    return json.dumps({path: entries})


_RECORDED_PATH = "/build/worktrees/swarm_x/Palace/OPDS/Foo.swift"
_GOOD_ENTRIES = [
    {"isExecutable": False, "line": 1},                      # not executable → skip
    {"isExecutable": False, "line": 2},
    {"isExecutable": True, "line": 10, "executionCount": 0},  # executable but uncovered → skip
    {"isExecutable": True, "line": 11, "executionCount": 0},
    {"isExecutable": True, "line": 86, "executionCount": 4},  # covered
    {"isExecutable": True, "line": 87, "executionCount": 1},  # covered
    {"isExecutable": True, "line": 99, "executionCount": 42}, # covered
]


class ParseArchiveCoveredLines(unittest.TestCase):

    def test_covered_lines_extractedCorrectly(self):
        text = _archive_json(_RECORDED_PATH, _GOOD_ENTRIES)
        self.assertEqual(mc.parse_archive_covered_lines(text), {86, 87, 99})

    def test_uncovered_executable_isExcluded(self):
        # executionCount 0 on an executable line must NOT be reported as covered.
        text = _archive_json(_RECORDED_PATH, [
            {"isExecutable": True, "line": 5, "executionCount": 0},
        ])
        self.assertEqual(mc.parse_archive_covered_lines(text), set())

    def test_nonExecutable_withCount_isExcluded(self):
        # Defensive: a non-executable line should never count even if a count
        # leaks in.
        text = _archive_json(_RECORDED_PATH, [
            {"isExecutable": False, "line": 5, "executionCount": 9},
        ])
        self.assertEqual(mc.parse_archive_covered_lines(text), set())

    def test_emptyString_returnsNone(self):
        self.assertIsNone(mc.parse_archive_covered_lines(""))
        self.assertIsNone(mc.parse_archive_covered_lines("   \n  "))

    def test_malformedJson_returnsNone(self):
        self.assertIsNone(mc.parse_archive_covered_lines("{not json"))
        self.assertIsNone(mc.parse_archive_covered_lines("[1, 2, 3"))

    def test_unexpectedTopShape_returnsNone(self):
        # A JSON list (not the expected dict) → unknown.
        self.assertIsNone(mc.parse_archive_covered_lines("[]"))
        self.assertIsNone(mc.parse_archive_covered_lines("[{\"line\": 1}]"))

    def test_emptyDict_returnsNone(self):
        self.assertIsNone(mc.parse_archive_covered_lines("{}"))

    def test_valueNotList_returnsNone(self):
        self.assertIsNone(mc.parse_archive_covered_lines('{"path": "nope"}'))

    def test_entryNotDict_returnsNone(self):
        # A non-dict entry signals an unexpected shape → don't half-trust it.
        text = _archive_json(_RECORDED_PATH, ["unexpected", {"isExecutable": True, "line": 1, "executionCount": 1}])
        self.assertIsNone(mc.parse_archive_covered_lines(text))

    def test_missingExecutionCount_treatedAsZero(self):
        # An executable entry with no executionCount key → not covered.
        text = _archive_json(_RECORDED_PATH, [
            {"isExecutable": True, "line": 7},
        ])
        self.assertEqual(mc.parse_archive_covered_lines(text), set())

    def test_nonIntLine_isSkipped(self):
        text = _archive_json(_RECORDED_PATH, [
            {"isExecutable": True, "line": "x", "executionCount": 3},
            {"isExecutable": True, "line": 8, "executionCount": 3},
        ])
        self.assertEqual(mc.parse_archive_covered_lines(text), {8})


class RecordedPathFor(unittest.TestCase):

    def test_suffixMatch_findsWorktreePath(self):
        # Recorded paths are build-time paths that differ from repo_root.
        file_list = (
            "/Users/x/.claude/worktrees/swarm_a/Palace/Accounts/AccountsManager.swift\n"
            "/Users/x/.claude/worktrees/swarm_a/Palace/OPDS/Foo.swift\n"
        )
        self.assertEqual(
            mc._recorded_path_for(file_list, "Palace/OPDS/Foo.swift"),
            "/Users/x/.claude/worktrees/swarm_a/Palace/OPDS/Foo.swift",
        )

    def test_componentBoundary_preventsPartialLeafMatch(self):
        # `Foo.swift` must NOT match a path ending in `OtherFoo.swift`.
        file_list = "/build/Palace/OPDS/OtherFoo.swift\n"
        self.assertIsNone(mc._recorded_path_for(file_list, "Palace/OPDS/Foo.swift"))

    def test_noMatch_returnsNone(self):
        file_list = "/build/Palace/Other/Bar.swift\n"
        self.assertIsNone(mc._recorded_path_for(file_list, "Palace/OPDS/Foo.swift"))

    def test_leadingSlashInRelpath_isTolerated(self):
        file_list = "/build/Palace/OPDS/Foo.swift\n"
        self.assertEqual(
            mc._recorded_path_for(file_list, "/Palace/OPDS/Foo.swift"),
            "/build/Palace/OPDS/Foo.swift",
        )

    def test_blankLines_ignored(self):
        file_list = "\n\n/build/Palace/OPDS/Foo.swift\n\n"
        self.assertEqual(
            mc._recorded_path_for(file_list, "Palace/OPDS/Foo.swift"),
            "/build/Palace/OPDS/Foo.swift",
        )


class CoveredLinesIntegration(unittest.TestCase):
    """covered_lines() top-level guards (no xccov subprocess invoked)."""

    def test_missingBundle_returnsNone(self):
        self.assertIsNone(mc.covered_lines("/no/such/bundle.xcresult", "Palace/Foo.swift", "/repo"))

    def test_emptyBundlePath_returnsNone(self):
        self.assertIsNone(mc.covered_lines("", "Palace/Foo.swift", "/repo"))

    def test_fileListFailure_returnsNone(self):
        # If xccov can't produce a file-list (returns None), degrade to None.
        # We point at an existing path (this test file) so the os.path.exists
        # guard passes, then _run_xccov fails because it isn't a real bundle.
        here = os.path.abspath(__file__)
        self.assertIsNone(mc.covered_lines(here, "Palace/Foo.swift", "/repo"))


class TestsForLines(unittest.TestCase):
    """tests_for_lines is intentionally stubbed to None (per-test attribution
    is unavailable in Xcode 26 — see module docstring). Pin that contract so a
    future change that returns a (possibly wrong) map is a deliberate decision,
    not an accident."""

    def test_returnsNone_always(self):
        self.assertIsNone(mc.tests_for_lines("/any.xcresult", "Palace/Foo.swift", {1, 2, 3}, "/repo"))
        self.assertIsNone(mc.tests_for_lines("", "Palace/Foo.swift", set(), "/repo"))


class IsSuppressed(unittest.TestCase):

    def setUp(self):
        self.supps = [
            {"line_text": "for i in 0 ..< count {", "original": "<", "mutated": "<=",
             "reason": "loop bound equivalent"},
            {"line_text": "guard x >= 0 else { return }", "original": ">=", "mutated": ">",
             "reason": "x is non-negative"},
        ]

    def test_exactMatch_isSuppressed(self):
        self.assertTrue(mc.is_suppressed(self.supps, "for i in 0 ..< count {", "<", "<="))

    def test_whitespaceInsensitive_lineText(self):
        # A re-indent of the same line must still match (both sides stripped).
        self.assertTrue(mc.is_suppressed(self.supps, "      for i in 0 ..< count {   ", "<", "<="))

    def test_differentOriginal_notSuppressed(self):
        self.assertFalse(mc.is_suppressed(self.supps, "for i in 0 ..< count {", "<=", "<="))

    def test_differentMutated_notSuppressed(self):
        self.assertFalse(mc.is_suppressed(self.supps, "for i in 0 ..< count {", "<", "<"))

    def test_differentLineText_notSuppressed(self):
        self.assertFalse(mc.is_suppressed(self.supps, "while i < count {", "<", "<="))

    def test_emptySuppressions_neverSuppresses(self):
        self.assertFalse(mc.is_suppressed([], "for i in 0 ..< count {", "<", "<="))

    def test_secondEntry_alsoMatches(self):
        self.assertTrue(mc.is_suppressed(self.supps, "guard x >= 0 else { return }", ">=", ">"))

    def test_noneLineText_doesNotCrash(self):
        self.assertFalse(mc.is_suppressed(self.supps, None, "<", "<="))


class LoadSuppressions(unittest.TestCase):

    def _write(self, repo_root, leaf, content_str):
        d = os.path.join(repo_root, ".forgeos", "mutation-suppressions")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"{leaf}.json"), "w", encoding="utf-8") as f:
            f.write(content_str)

    def test_absentFile_returnsEmptyList(self):
        with tempfile.TemporaryDirectory() as repo:
            self.assertEqual(mc.load_suppressions(repo, "Palace/Foo/Bar.swift"), [])

    def test_presentFile_loadsEntries(self):
        with tempfile.TemporaryDirectory() as repo:
            self._write(repo, "Bar", json.dumps([
                {"line_text": "a > b", "original": ">", "mutated": ">=", "reason": "r"},
            ]))
            supps = mc.load_suppressions(repo, "Palace/Foo/Bar.swift")
            self.assertEqual(len(supps), 1)
            self.assertEqual(supps[0]["original"], ">")

    def test_leafDerivation_stripsSwiftAndPath(self):
        # source_relpath Palace/A/B/TPPBookState.swift → leaf TPPBookState.json
        with tempfile.TemporaryDirectory() as repo:
            self._write(repo, "TPPBookState", json.dumps([
                {"line_text": "x == y", "original": "==", "mutated": "!=", "reason": "r"},
            ]))
            supps = mc.load_suppressions(repo, "Palace/Book/Models/TPPBookState.swift")
            self.assertEqual(len(supps), 1)

    def test_malformedJson_returnsEmptyList(self):
        with tempfile.TemporaryDirectory() as repo:
            self._write(repo, "Bar", "{ this is not valid json")
            self.assertEqual(mc.load_suppressions(repo, "Palace/Foo/Bar.swift"), [])

    def test_nonListTopLevel_returnsEmptyList(self):
        with tempfile.TemporaryDirectory() as repo:
            self._write(repo, "Bar", json.dumps({"line_text": "a > b"}))
            self.assertEqual(mc.load_suppressions(repo, "Palace/Foo/Bar.swift"), [])

    def test_malformedEntries_filteredOut(self):
        # Mix of well-formed and ill-formed entries: keep only the complete ones.
        with tempfile.TemporaryDirectory() as repo:
            self._write(repo, "Bar", json.dumps([
                {"line_text": "a > b", "original": ">", "mutated": ">=", "reason": "ok"},
                {"line_text": "missing operators"},          # dropped
                "not a dict",                                  # dropped
                {"original": ">", "mutated": ">="},            # missing line_text → dropped
            ]))
            supps = mc.load_suppressions(repo, "Palace/Foo/Bar.swift")
            self.assertEqual(len(supps), 1)
            self.assertEqual(supps[0]["line_text"], "a > b")

    def test_loadThenIsSuppressed_roundTrip(self):
        # End-to-end: a written suppression actually suppresses its mutant.
        with tempfile.TemporaryDirectory() as repo:
            self._write(repo, "Bar", json.dumps([
                {"line_text": "  for i in 0 ..< n {  ", "original": "<", "mutated": "<=", "reason": "r"},
            ]))
            supps = mc.load_suppressions(repo, "Palace/Foo/Bar.swift")
            self.assertTrue(mc.is_suppressed(supps, "for i in 0 ..< n {", "<", "<="))
            self.assertFalse(mc.is_suppressed(supps, "for i in 0 ..< n {", ">", ">="))


class ExampleFileIsNeverLoadedForRealSource(unittest.TestCase):
    """The committed EXAMPLE.json must never be picked up by load_suppressions
    for a real source file (there is no EXAMPLE.swift). Guards the README claim."""

    def test_exampleLeafDoesNotCollideWithRealSources(self):
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        # A real source whose leaf is NOT 'EXAMPLE' must load [] from the real dir
        # (assuming no suppressions committed for it). This also proves the real
        # committed README/EXAMPLE.json don't accidentally suppress anything.
        self.assertEqual(
            mc.load_suppressions(repo_root, "Palace/Book/Models/TPPBookState.swift"),
            [],
        )


if __name__ == "__main__":
    unittest.main()
