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

from palace_mutate import any_tests_ran


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


if __name__ == "__main__":
    unittest.main()
