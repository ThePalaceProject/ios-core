#!/usr/bin/env python3
"""
Unit tests for palace_mutate_parallel.py PURE orchestration logic.

These tests NEVER create a real git worktree, boot a simulator, or invoke
xcodebuild. Everything exercised here is the factored pure logic (worker-count
math, the serial/parallel cost gate, sim round-robin, file filtering, report
aggregation, argv assembly). subprocess-touching helpers are exercised only via
injected `runner` callables.

Run: python3 -m unittest scripts.test_palace_mutate_parallel
  or: python3 scripts/test_palace_mutate_parallel.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from palace_mutate_parallel import (
    compute_worker_count,
    should_run_parallel,
    assign_sims,
    filter_prod_swift,
    changed_prod_swift_files,
    resolve_tests_for_file,
    aggregate_reports,
    aggregate_exit_code,
    build_palace_mutate_argv,
    FileResult,
    DEFAULT_SIM_UDIDS,
)


# Small stand-in for subprocess.CompletedProcess for injected runners.
class _FakeProc:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class ComputeWorkerCount(unittest.TestCase):
    """Default = min(#sims, max(1, ncpu//4), #files); explicit honored+clamped."""

    def test_zeroFiles_zeroWorkers(self):
        self.assertEqual(compute_worker_count(0, 3, 24), 0)

    def test_oneFile_oneWorker(self):
        # Clamped to #files even though sims=3 and ncpu//4=6.
        self.assertEqual(compute_worker_count(1, 3, 24), 1)

    def test_manyFiles_clampedBySims(self):
        # 10 files, 3 sims, ncpu//4 = 6 -> sims wins (3).
        self.assertEqual(compute_worker_count(10, 3, 24), 3)

    def test_manyFiles_clampedByCpu(self):
        # 10 files, 8 sims, ncpu=8 -> ncpu//4=2 wins.
        self.assertEqual(compute_worker_count(10, 8, 8), 2)

    def test_manyFiles_clampedByFiles(self):
        # 2 files, 8 sims, ncpu=24 (//4=6) -> files wins (2).
        self.assertEqual(compute_worker_count(2, 8, 24), 2)

    def test_lowCpu_floorOfOne(self):
        # ncpu=2 -> //4 == 0, but max(1, ...) keeps at least one worker.
        self.assertEqual(compute_worker_count(5, 3, 2), 1)

    def test_zeroSims_floorOfOne(self):
        # Pathological: no sims declared. max(1, num_sims) keeps a worker so
        # the run degrades to serial-ish rather than producing 0 workers.
        self.assertEqual(compute_worker_count(5, 0, 24), 1)

    def test_explicitRequested_honored(self):
        self.assertEqual(compute_worker_count(10, 3, 24, requested=2), 2)

    def test_explicitRequested_clampedToFiles(self):
        # Can't run more workers than files.
        self.assertEqual(compute_worker_count(2, 8, 24, requested=8), 2)

    def test_explicitRequested_zeroClampedToOne(self):
        self.assertEqual(compute_worker_count(5, 3, 24, requested=0), 1)

    def test_explicitRequested_negativeClampedToOne(self):
        self.assertEqual(compute_worker_count(5, 3, 24, requested=-4), 1)


class ShouldRunParallel(unittest.TestCase):
    """Cost gate: parallel only when >=2 files AND >=2 workers."""

    def test_oneFile_serial(self):
        self.assertFalse(should_run_parallel(1, 1))

    def test_oneFile_evenWithManyWorkers_serial(self):
        # worker_count can't actually be 5 for 1 file, but the gate is robust.
        self.assertFalse(should_run_parallel(1, 5))

    def test_twoFilesOneWorker_serial(self):
        # --workers 1 forces serial even with 2 files.
        self.assertFalse(should_run_parallel(2, 1))

    def test_twoFilesTwoWorkers_parallel(self):
        self.assertTrue(should_run_parallel(2, 2))

    def test_manyFilesManyWorkers_parallel(self):
        self.assertTrue(should_run_parallel(10, 3))

    def test_zeroFiles_serial(self):
        self.assertFalse(should_run_parallel(0, 0))


class AssignSims(unittest.TestCase):

    def test_roundRobin_fewerWorkersThanSims(self):
        sims = ["A", "B", "C"]
        self.assertEqual(assign_sims(2, sims), ["A", "B"])

    def test_roundRobin_equalWorkersAndSims(self):
        sims = ["A", "B", "C"]
        self.assertEqual(assign_sims(3, sims), ["A", "B", "C"])

    def test_roundRobin_moreWorkersThanSims_wraps(self):
        # Defended pathological case: workers wrap and share sims.
        sims = ["A", "B", "C"]
        self.assertEqual(assign_sims(5, sims), ["A", "B", "C", "A", "B"])

    def test_oneWorker_firstSim(self):
        self.assertEqual(assign_sims(1, ["A", "B", "C"]), ["A"])

    def test_noSims_empty(self):
        self.assertEqual(assign_sims(3, []), [])

    def test_defaultSimsAreThree(self):
        # The pool has exactly three UDIDs; assigning 3 workers uses each once.
        self.assertEqual(len(set(assign_sims(3, DEFAULT_SIM_UDIDS))), 3)


class FilterProdSwift(unittest.TestCase):

    def test_keepsProductionSwift(self):
        paths = ["Palace/Audiobooks/Player.swift", "Palace/MyBooks/Borrow.swift"]
        self.assertEqual(filter_prod_swift(paths), paths)

    def test_dropsNonSwift(self):
        self.assertEqual(filter_prod_swift(["Palace/Foo.m", "README.md"]), [])

    def test_dropsTestBundle(self):
        self.assertEqual(filter_prod_swift(["PalaceTests/Audiobooks/PlayerTests.swift"]), [])

    def test_dropsTestSuffixedSwiftUnderPalace(self):
        # A *Tests.swift file that happens to live under Palace/ is still a test.
        self.assertEqual(filter_prod_swift(["Palace/Audiobooks/PlayerTests.swift"]), [])

    def test_dropsNonPalacePath(self):
        self.assertEqual(filter_prod_swift(["scripts/foo.swift"]), [])

    def test_stripsWhitespaceAndBlanks(self):
        self.assertEqual(
            filter_prod_swift(["  Palace/A.swift  ", "", "   "]),
            ["Palace/A.swift"])

    def test_mixed(self):
        paths = [
            "Palace/Audiobooks/Player.swift",       # keep
            "PalaceTests/PlayerTests.swift",        # drop (test bundle)
            "Palace/MyBooks/BorrowTests.swift",     # drop (Tests suffix)
            "docs/notes.md",                        # drop (non-swift)
            "Palace/SignInLogic/Login.swift",       # keep
        ]
        self.assertEqual(
            filter_prod_swift(paths),
            ["Palace/Audiobooks/Player.swift", "Palace/SignInLogic/Login.swift"])


class ChangedProdSwiftFiles(unittest.TestCase):
    """changed_prod_swift_files via injected runner — no real git."""

    def test_parsesAndFilters(self):
        def runner(argv):
            return _FakeProc(0, stdout=(
                "Palace/Audiobooks/Player.swift\n"
                "PalaceTests/PlayerTests.swift\n"
                "Palace/MyBooks/BorrowTests.swift\n"
                "Palace/SignInLogic/Login.swift\n"))
        out = changed_prod_swift_files("origin/develop", runner=runner)
        self.assertEqual(out, ["Palace/Audiobooks/Player.swift",
                               "Palace/SignInLogic/Login.swift"])

    def test_gitFailure_returnsEmpty(self):
        def runner(argv):
            return _FakeProc(128, stderr="fatal: bad revision")
        self.assertEqual(changed_prod_swift_files("nope", runner=runner), [])

    def test_emptyDiff_returnsEmpty(self):
        self.assertEqual(
            changed_prod_swift_files("x", runner=lambda a: _FakeProc(0, "")), [])


class ResolveTestsForFile(unittest.TestCase):

    def test_parsesSelectors(self):
        def runner(argv):
            return _FakeProc(0, stdout="PalaceTests/PlayerTests\nPalaceTests/LoaderTests\n")
        self.assertEqual(
            resolve_tests_for_file("Palace/Audiobooks/Player.swift", runner=runner),
            ["PalaceTests/PlayerTests", "PalaceTests/LoaderTests"])

    def test_resolverFailure_returnsEmpty(self):
        self.assertEqual(
            resolve_tests_for_file("x", runner=lambda a: _FakeProc(1)), [])

    def test_emptyOutput_returnsEmpty(self):
        self.assertEqual(
            resolve_tests_for_file("x", runner=lambda a: _FakeProc(0, "")), [])


class BuildPalaceMutateArgv(unittest.TestCase):

    def test_forwardsFileTestsReportAndPassthrough(self):
        argv = build_palace_mutate_argv(
            "Palace/Audiobooks/Player.swift",
            ["PalaceTests/PlayerTests", "PalaceTests/LoaderTests"],
            "/tmp/r.json",
            ["--diff-only", "--max-mutations", "10", "--no-cache"])
        self.assertIn("--file", argv)
        self.assertIn("Palace/Audiobooks/Player.swift", argv)
        # Each test becomes its own --tests pair.
        self.assertEqual(argv.count("--tests"), 2)
        self.assertIn("PalaceTests/PlayerTests", argv)
        self.assertIn("PalaceTests/LoaderTests", argv)
        self.assertIn("--report", argv)
        self.assertIn("/tmp/r.json", argv)
        # Passthrough forwarded verbatim at the tail.
        for flag in ("--diff-only", "--max-mutations", "10", "--no-cache"):
            self.assertIn(flag, argv)
        # Targets palace_mutate.py.
        self.assertTrue(any(a.endswith("palace_mutate.py") for a in argv))


def _file_result(file, exit_code, *, killed=0, survived=0, uncovered=0,
                 suppressed=0, errored=0, is_critical=False, cps=0, error=""):
    """Build a synthetic FileResult with an embedded palace_mutate-shaped
    report. Mirrors build_report's summary schema so aggregation is exercised
    against the real key names."""
    report = {
        "file": file,
        "summary": {
            "killed": killed, "survived": survived, "errored": errored,
            "uncovered": uncovered, "suppressed": suppressed,
            "is_critical_path": is_critical, "critical_path_survivors": cps,
        },
    }
    return FileResult(file=file, exit_code=exit_code, report=report, error=error)


class AggregateReports(unittest.TestCase):

    def test_sumsAcrossFiles(self):
        results = [
            _file_result("a.swift", 0, killed=8, survived=2, uncovered=1, suppressed=1),
            _file_result("b.swift", 0, killed=6, survived=4, uncovered=2),
        ]
        agg = aggregate_reports(results)
        t = agg["totals"]
        self.assertEqual(t["killed"], 14)
        self.assertEqual(t["survived"], 6)
        self.assertEqual(t["uncovered"], 3)
        self.assertEqual(t["suppressed"], 1)
        # Overall kill rate over RUN mutants only: 14 / (14+6) = 70%.
        self.assertEqual(agg["overall_kill_rate_pct"], 70.0)

    def test_uncoveredSuppressedDoNotAffectKillRate(self):
        # 100 uncovered, but 1 killed / 1 survived among run -> 50%, not buried.
        results = [_file_result("a.swift", 1, killed=1, survived=1,
                                uncovered=100, suppressed=50)]
        agg = aggregate_reports(results)
        self.assertEqual(agg["overall_kill_rate_pct"], 50.0)

    def test_overallPassWhenAllFilesPass(self):
        results = [_file_result("a.swift", 0, killed=10),
                   _file_result("b.swift", 0, killed=5)]
        agg = aggregate_reports(results)
        self.assertTrue(agg["overall_passed"])
        self.assertEqual(agg["files_failed"], 0)
        self.assertEqual(aggregate_exit_code(agg), 0)

    def test_overallFailWhenAnyFileFails(self):
        results = [_file_result("a.swift", 0, killed=10),
                   _file_result("b.swift", 1, killed=1, survived=9)]
        agg = aggregate_reports(results)
        self.assertFalse(agg["overall_passed"])
        self.assertEqual(agg["files_failed"], 1)
        self.assertEqual(aggregate_exit_code(agg), 1)

    def test_criticalPathSurvivorOverride_surfaced(self):
        # A critical-path file with a consequential survivor: palace_mutate would
        # have exited 1, so the file fails, the aggregate fails, AND the
        # any_critical_path_survivor flag is set for visibility.
        results = [
            _file_result("Palace/Audiobooks/P.swift", 1, killed=9, survived=1,
                         is_critical=True, cps=1),
        ]
        agg = aggregate_reports(results)
        self.assertFalse(agg["overall_passed"])
        self.assertTrue(agg["any_critical_path_survivor"])
        self.assertEqual(agg["totals"]["critical_path_survivors"], 1)
        self.assertEqual(aggregate_exit_code(agg), 1)

    def test_criticalSurvivorNotSetForNonCriticalFile(self):
        # A non-critical file with survivors does NOT trip the critical flag.
        results = [_file_result("Palace/Catalog/X.swift", 1, killed=1, survived=9,
                                is_critical=False, cps=0)]
        agg = aggregate_reports(results)
        self.assertFalse(agg["any_critical_path_survivor"])

    def test_perFileKillRates(self):
        results = [
            _file_result("a.swift", 0, killed=3, survived=1),  # 75%
            _file_result("b.swift", 1, killed=1, survived=3),  # 25%
        ]
        agg = aggregate_reports(results)
        rates = {pf["file"]: pf["kill_rate_pct"] for pf in agg["per_file"]}
        self.assertEqual(rates["a.swift"], 75.0)
        self.assertEqual(rates["b.swift"], 25.0)
        passed = {pf["file"]: pf["passed"] for pf in agg["per_file"]}
        self.assertTrue(passed["a.swift"])
        self.assertFalse(passed["b.swift"])

    def test_fileWithNoReport_countedAsFailWithError(self):
        # A worker whose palace_mutate crashed before writing a report: exit
        # non-zero, no report. Must count toward files_failed and NOT crash.
        fr = FileResult(file="a.swift", exit_code=2, report=None,
                        error="no report produced (exit 2)")
        agg = aggregate_reports([fr])
        self.assertFalse(agg["overall_passed"])
        self.assertEqual(agg["files_failed"], 1)
        self.assertEqual(agg["per_file"][0]["error"], "no report produced (exit 2)")

    def test_zeroRunMutants_killRateZero_butNotAutoFail(self):
        # All uncovered: nothing ran. palace_mutate exits 0; aggregate passes.
        results = [_file_result("a.swift", 0, uncovered=5)]
        agg = aggregate_reports(results)
        self.assertEqual(agg["overall_kill_rate_pct"], 0.0)
        self.assertTrue(agg["overall_passed"])


if __name__ == "__main__":
    unittest.main()
