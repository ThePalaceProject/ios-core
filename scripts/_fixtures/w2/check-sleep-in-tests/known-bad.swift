// PalaceTests/Fixtures/SleepInTestsKnownBad.swift
//
// KNOWN-BAD fixture for check-sleep-in-tests.py.
// Five unmarked sleep sites → expected: 5 findings.

import XCTest

final class SleepInTestsKnownBad: XCTestCase {

    func testTaskSleepNoMarker() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testThreadSleepNoMarker() {
        Thread.sleep(forTimeInterval: 0.1)
    }

    func testWaitForConditionNoMarker() {
        waitForCondition(timeout: 0.5) { true }
    }

    func testBareSleepNoMarker() {
        sleep(1)
    }

    func testUsleepNoMarker() {
        usleep(500_000)
    }
}
