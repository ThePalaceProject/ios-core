#!/usr/bin/env python3
"""
Unit tests for palace_mutate.py helpers.

Run: python3 -m unittest scripts.test_palace_mutate
  or: python3 scripts/test_palace_mutate.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from palace_mutate import (
    any_tests_ran,
    classify_test_outcome,
    compute_mutant_key,
    is_critical_path,
    count_critical_path_survivors,
    build_report,
    compute_exit_code,
    resolve_fast_flags,
    build_xcodebuild_command,
    discover_mutations,
    DEFAULT_FAST_FLAGS,
    CONSEQUENTIAL_OPS,
)


class ClassifyTestOutcome(unittest.TestCase):
    """A timeout or a build-failure (no tests ran) must grade 'errored', not
    'failed' — otherwise a wedged/uncompilable mutant inflates the kill rate."""

    def test_tests_passed_isSurvived(self):
        self.assertEqual(
            classify_test_outcome(timed_out=False, tests_ran=True, succeeded=True),
            "passed")

    def test_tests_ran_and_failed_isKilled(self):
        # A real test failure IS the mutant being caught.
        self.assertEqual(
            classify_test_outcome(timed_out=False, tests_ran=True, succeeded=False),
            "failed")

    def test_timeout_isErrored_notFailed(self):
        # A wedged run is not a caught mutant — must not count as killed.
        self.assertEqual(
            classify_test_outcome(timed_out=True, tests_ran=False, succeeded=False),
            "errored")
        # Even if some output was captured before the hang, a timeout is errored.
        self.assertEqual(
            classify_test_outcome(timed_out=True, tests_ran=True, succeeded=False),
            "errored")

    def test_noTestsRan_isErrored_notFailed(self):
        # Build failure / misconfiguration: zero tests executed — not a catch.
        self.assertEqual(
            classify_test_outcome(timed_out=False, tests_ran=False, succeeded=False),
            "errored")


class AnyTestsRan(unittest.TestCase):

    def test_zero_test_run_isDetected(self):
        # xcodebuild output when -only-testing matches no class:
        # the per-suite Executed lines are all 0, despite ** TEST SUCCEEDED **
        output = """
Test Suite 'Selected tests' started at 2026-04-27
Test Suite 'PalaceTests.xctest' started at 2026-04-27
Test Suite 'PalaceTests.xctest' passed at 2026-04-27
\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
Test Suite 'Selected tests' passed at 2026-04-27
\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds
** TEST SUCCEEDED **
"""
        self.assertFalse(any_tests_ran(output),
                         "0-test runs must be detected so callers don't grade SURVIVED against an empty suite")

    def test_normal_run_isDetected(self):
        output = """
Test Suite 'TPPSignInBusinessLogicTests' started at 2026-04-27
Test Case '-[PalaceTests.TPPSignInBusinessLogicTests testFoo]' started.
Test Case '-[PalaceTests.TPPSignInBusinessLogicTests testFoo]' passed (0.123 seconds).
Test Suite 'TPPSignInBusinessLogicTests' passed at 2026-04-27
\t Executed 12 tests, with 0 failures (0 unexpected) in 0.812 (0.822) seconds
** TEST SUCCEEDED **
"""
        self.assertTrue(any_tests_ran(output))

    def test_partialFailure_isDetected(self):
        # Even if a suite reported 0 (e.g. one bundle no-op'd), if ANY suite
        # ran tests, we count as having executed tests — and the pass/fail
        # signal flows through the ** TEST SUCCEEDED ** check separately.
        output = """
\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
\t Executed 5 tests, with 1 failure (0 unexpected) in 0.500 (0.502) seconds
** TEST FAILED **
"""
        self.assertTrue(any_tests_ran(output))

    def test_emptyOutput_treatedAsZero(self):
        self.assertFalse(any_tests_ran(""))

    def test_singleTestRun(self):
        # Boundary: exactly 1 test executed must be detected (regex must accept [1-9]\d*)
        output = "\t Executed 1 test, with 0 failures"
        self.assertTrue(any_tests_ran(output))


class ComputeMutantKey(unittest.TestCase):
    """compute_mutant_key must be STABLE (same inputs -> same key) and
    DISAMBIGUATING (same line_text, different context -> different key)."""

    def _key(self, **over):
        base = dict(
            tests=["PalaceTests/FooTests"],
            context_before="let a = 1",
            line_text="if x > 0 {",
            context_after="return a",
            original=">",
            mutated=">=",
        )
        base.update(over)
        return compute_mutant_key(**base)

    def test_stability_sameInputs_sameKey(self):
        self.assertEqual(self._key(), self._key())

    def test_keyIs16Hex(self):
        k = self._key()
        self.assertEqual(len(k), 16)
        int(k, 16)  # raises if not hex

    def test_disambiguation_sameLineDifferentContextBefore(self):
        a = self._key(context_before="let a = 1")
        b = self._key(context_before="let b = 99")
        self.assertNotEqual(a, b, "identical line in different preceding context must key differently")

    def test_disambiguation_sameLineDifferentContextAfter(self):
        a = self._key(context_after="return a")
        b = self._key(context_after="return b")
        self.assertNotEqual(a, b, "identical line in different following context must key differently")

    def test_locality_lineNumberNotInKey(self):
        # Two mutants with identical local context but (implicitly) at different
        # file positions produce the SAME key — the key intentionally does not
        # encode the absolute line number, so edits elsewhere reuse the result.
        self.assertEqual(self._key(), self._key())

    def test_testSelectionChangesKey(self):
        a = self._key(tests=["PalaceTests/FooTests"])
        b = self._key(tests=["PalaceTests/BarTests"])
        self.assertNotEqual(a, b)

    def test_testOrderDoesNotChangeKey(self):
        a = self._key(tests=["PalaceTests/A", "PalaceTests/B"])
        b = self._key(tests=["PalaceTests/B", "PalaceTests/A"])
        self.assertEqual(a, b, "tests are sorted before hashing")

    def test_operatorFlipChangesKey(self):
        a = self._key(original=">", mutated=">=")
        b = self._key(original=">", mutated="<")
        self.assertNotEqual(a, b)


class CriticalPathClassification(unittest.TestCase):

    def test_audiobooks_isCritical(self):
        self.assertTrue(is_critical_path("Palace/Audiobooks/AudiobookLoader.swift"))

    def test_signInLogic_isCritical(self):
        self.assertTrue(is_critical_path("Palace/SignInLogic/TPPSignInBusinessLogic.swift"))

    def test_downloadPrefix_isCritical(self):
        self.assertTrue(is_critical_path("Palace/MyBooks/DownloadAuthRetryHandler.swift"))

    def test_borrowPrefix_isCritical(self):
        self.assertTrue(is_critical_path("Palace/MyBooks/BorrowOperation.swift"))

    def test_bookReturnPrefix_isCritical(self):
        self.assertTrue(is_critical_path("Palace/MyBooks/BookReturnService.swift"))

    def test_migrations_isCritical(self):
        self.assertTrue(is_critical_path("Palace/Migrations/SomeMigration.swift"))

    def test_networkResponder_isCritical(self):
        self.assertTrue(is_critical_path("Palace/Network/TPPNetworkResponder.swift"))

    def test_networkExecutor_isCritical(self):
        self.assertTrue(is_critical_path("Palace/Network/TPPNetworkExecutor.swift"))

    def test_palaceAuth_isCritical(self):
        self.assertTrue(is_critical_path("Palace/Packages/PalaceAuth/AuthThing.swift"))

    def test_absolutePrefix_isCritical(self):
        # CRITICAL_PATH_REGEX anchors on (^|/) before Palace/, so an absolute
        # worktree path still classifies.
        self.assertTrue(is_critical_path("/Users/x/wt/Palace/Audiobooks/Player.swift"))

    def test_unrelatedFile_isNotCritical(self):
        self.assertFalse(is_critical_path("Palace/Catalog/CatalogView.swift"))

    def test_networkOtherFile_isNotCritical(self):
        # Only the two named Network files are critical, not the whole dir.
        self.assertFalse(is_critical_path("Palace/Network/TPPNetworkQueue.swift"))

    def test_myBooksOtherFile_isNotCritical(self):
        self.assertFalse(is_critical_path("Palace/MyBooks/MyBooksView.swift"))


class CountCriticalPathSurvivors(unittest.TestCase):

    @staticmethod
    def _r(status, op):
        return {"status": status, "mutation": {"op": op, "line": 1}}

    def test_countsConsequentialSurvivorsOnly(self):
        results = [
            self._r("survived", "cmp"),     # counts
            self._r("survived", "bool"),    # counts
            self._r("survived", "assign"),  # excluded (assign)
            self._r("killed", "cmp"),       # not a survivor
            self._r("uncovered", "cond"),   # not a survivor
            self._r("survived", "retval"),  # counts
        ]
        self.assertEqual(count_critical_path_survivors(results), 3)

    def test_assignSurvivorExcluded(self):
        results = [self._r("survived", "assign")]
        self.assertEqual(count_critical_path_survivors(results), 0)

    def test_allConsequentialOpsCounted(self):
        results = [self._r("survived", op) for op in sorted(CONSEQUENTIAL_OPS)]
        self.assertEqual(count_critical_path_survivors(results), len(CONSEQUENTIAL_OPS))

    def test_empty(self):
        self.assertEqual(count_critical_path_survivors([]), 0)


class BuildReportSchema(unittest.TestCase):
    """build_report must ADD keys without changing the existing schema, and must
    keep killed/survived counts free of uncovered/suppressed mutants."""

    @staticmethod
    def _r(status, op="cmp", line=10):
        return {"status": status, "mutation": {"op": op, "line": line}}

    def test_uncoveredAndSuppressedNotCountedAsRun(self):
        results = [
            self._r("killed"),
            self._r("survived"),
            self._r("uncovered", line=20),
            self._r("suppressed"),
        ]
        rep = build_report(file_relpath="Palace/Catalog/X.swift", tests=["T"],
                           seed=1, results=results, planned=4, partial=False)
        s = rep["summary"]
        self.assertEqual(s["killed"], 1)
        self.assertEqual(s["survived"], 1)
        self.assertEqual(s["uncovered"], 1)
        self.assertEqual(s["suppressed"], 1)
        # kill rate over RUN mutants only: 1 killed / (1+1) = 50%
        self.assertEqual(s["kill_rate_pct"], 50.0)

    def test_additiveKeysPresent(self):
        rep = build_report(file_relpath="Palace/Catalog/X.swift", tests=["T"],
                           seed=1, results=[self._r("killed")], planned=1, partial=False)
        s = rep["summary"]
        for k in ("uncovered", "suppressed", "is_critical_path", "critical_path_survivors"):
            self.assertIn(k, s)
        self.assertIn("coverage_gap", rep)

    def test_existingKeysPreserved(self):
        rep = build_report(file_relpath="Palace/Catalog/X.swift", tests=["T"],
                           seed=1, results=[self._r("killed")], planned=1, partial=True)
        s = rep["summary"]
        for k in ("killed", "survived", "errored", "kill_rate_pct", "partial",
                  "completed_mutations", "planned_mutations"):
            self.assertIn(k, s)
        self.assertTrue(s["partial"])
        self.assertEqual(s["planned_mutations"], 1)
        for k in ("file", "tests", "seed", "results"):
            self.assertIn(k, rep)

    def test_coverageGapListsUncoveredPoints(self):
        results = [self._r("uncovered", op="bound", line=42),
                   self._r("killed", line=43)]
        rep = build_report(file_relpath="Palace/Catalog/X.swift", tests=["T"],
                           seed=1, results=results, planned=2, partial=False)
        self.assertEqual(rep["coverage_gap"], [{"line": 42, "op": "bound"}])

    def test_criticalPathSurvivorsCountedOnlyForCriticalFile(self):
        results = [self._r("survived", op="cmp")]
        # Non-critical file: survivors NOT counted as critical.
        non_crit = build_report(file_relpath="Palace/Catalog/X.swift", tests=["T"],
                                seed=1, results=results, planned=1, partial=False)
        self.assertFalse(non_crit["summary"]["is_critical_path"])
        self.assertEqual(non_crit["summary"]["critical_path_survivors"], 0)
        # Critical file: counted.
        crit = build_report(file_relpath="Palace/Audiobooks/Y.swift", tests=["T"],
                            seed=1, results=results, planned=1, partial=False)
        self.assertTrue(crit["summary"]["is_critical_path"])
        self.assertEqual(crit["summary"]["critical_path_survivors"], 1)


class ComputeExitCode(unittest.TestCase):
    """Exit contract: 0 ok, 1 low-kill (<50%) OR critical-path consequential
    survivor regardless of kill rate."""

    def test_highKillRate_nonCritical_exit0(self):
        s = {"killed": 9, "survived": 1, "kill_rate_pct": 90.0,
             "is_critical_path": False, "critical_path_survivors": 0}
        self.assertEqual(compute_exit_code(s), 0)

    def test_lowKillRate_exit1(self):
        s = {"killed": 1, "survived": 9, "kill_rate_pct": 10.0,
             "is_critical_path": False, "critical_path_survivors": 0}
        self.assertEqual(compute_exit_code(s), 1)

    def test_criticalPathSurvivor_overridesHighKillRate_exit1(self):
        # 90% kill rate would normally pass, but a critical-path consequential
        # survivor fails the gate REGARDLESS.
        s = {"killed": 9, "survived": 1, "kill_rate_pct": 90.0,
             "is_critical_path": True, "critical_path_survivors": 1}
        self.assertEqual(compute_exit_code(s), 1)

    def test_criticalPath_noConsequentialSurvivor_highKill_exit0(self):
        s = {"killed": 10, "survived": 0, "kill_rate_pct": 100.0,
             "is_critical_path": True, "critical_path_survivors": 0}
        self.assertEqual(compute_exit_code(s), 0)

    def test_noRunMutants_exit0(self):
        # All uncovered/suppressed -> nothing ran -> not a low-kill failure.
        s = {"killed": 0, "survived": 0, "kill_rate_pct": 0.0,
             "is_critical_path": False, "critical_path_survivors": 0}
        self.assertEqual(compute_exit_code(s), 0)


class FastFlags(unittest.TestCase):

    def setUp(self):
        # Snapshot + clear the env vars these tests manipulate.
        self._saved = {k: os.environ.get(k) for k in
                       ("PALACE_MUTATE_NO_FAST_FLAGS", "PALACE_MUTATE_XCB_EXTRA_FLAGS")}
        for k in self._saved:
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_defaultFlagsPresent(self):
        for flag in ("-disableAutomaticPackageResolution",
                     "-onlyUsePackageVersionsFromResolvedFile",
                     "-skipPackagePluginValidation",
                     "-parallel-testing-enabled",
                     "COMPILER_INDEX_STORE_ENABLE=NO"):
            self.assertIn(flag, DEFAULT_FAST_FLAGS)
        # -parallel-testing-enabled is followed by NO
        idx = DEFAULT_FAST_FLAGS.index("-parallel-testing-enabled")
        self.assertEqual(DEFAULT_FAST_FLAGS[idx + 1], "NO")

    def test_quietNotInDefaults(self):
        # -quiet would break any_tests_ran's 'Executed N tests' grep.
        self.assertNotIn("-quiet", DEFAULT_FAST_FLAGS)

    def test_resolve_default(self):
        self.assertEqual(resolve_fast_flags(), DEFAULT_FAST_FLAGS)

    def test_resolve_suppressed(self):
        os.environ["PALACE_MUTATE_NO_FAST_FLAGS"] = "1"
        self.assertEqual(resolve_fast_flags(), [])

    def test_resolve_overrideReplaces(self):
        os.environ["PALACE_MUTATE_XCB_EXTRA_FLAGS"] = "-foo -bar BAZ=NO"
        self.assertEqual(resolve_fast_flags(), ["-foo", "-bar", "BAZ=NO"])

    def test_buildCommand_includesFlagsAndOnlyTesting(self):
        cmd = build_xcodebuild_command(
            ["PalaceTests/FooTests"],
            fast_flags=DEFAULT_FAST_FLAGS,
            derived_data_args=[],
            coverage_bundle_path=None,
        )
        self.assertIn("-disableAutomaticPackageResolution", cmd)
        self.assertIn("-only-testing:PalaceTests/FooTests", cmd)
        self.assertNotIn("-enableCodeCoverage", cmd)

    def test_buildCommand_coverageBundle(self):
        cmd = build_xcodebuild_command(
            ["PalaceTests/FooTests"],
            fast_flags=[],
            derived_data_args=[],
            coverage_bundle_path="/tmp/x.xcresult",
        )
        self.assertIn("-enableCodeCoverage", cmd)
        i = cmd.index("-enableCodeCoverage")
        self.assertEqual(cmd[i + 1], "YES")
        self.assertIn("-resultBundlePath", cmd)
        self.assertIn("/tmp/x.xcresult", cmd)


class DiscoverMutationsContext(unittest.TestCase):
    """discover_mutations must populate context_before/after so the per-mutant
    cache key can disambiguate identical lines."""

    def test_contextCaptured(self):
        src = "let a = 1\nif x > 0 {\nreturn a\n"
        muts = discover_mutations(src)
        bound = [m for m in muts if m.op == "bound" and m.line == 2]
        self.assertTrue(bound, "expected a bound mutant on the `>` line")
        m = bound[0]
        self.assertEqual(m.context_before, "let a = 1")
        self.assertEqual(m.context_after, "return a")

    def test_contextAtFileBoundary(self):
        src = "x > 0\n"
        muts = discover_mutations(src)
        m = [mm for mm in muts if mm.op == "bound"][0]
        self.assertEqual(m.context_before, "")
        self.assertEqual(m.context_after, "")


if __name__ == "__main__":
    unittest.main()
