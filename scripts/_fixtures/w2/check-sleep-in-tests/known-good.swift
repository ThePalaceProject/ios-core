// PalaceTests/Fixtures/SleepInTestsKnownGood.swift
//
// KNOWN-GOOD fixture for check-sleep-in-tests.py.
// Every sleep site is either marked or replaced by a real wait. Expected: 0 findings.

import XCTest

final class SleepInTestsKnownGood: XCTestCase {

    func testTaskSleepWithMarker() async {
        // allow-sleep: simulating wallclock for a debounce gate; deterministic in CI.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testThreadSleepWithSameLineMarker() {
        Thread.sleep(forTimeInterval: 0.1) // allow-sleep: legacy CFRunLoop reentry guard.
    }

    func testExpectationsInsteadOfSleep() {
        let exp = expectation(description: "deferred")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }
}
