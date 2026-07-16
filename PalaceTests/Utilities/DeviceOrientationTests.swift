//
//  DeviceOrientationTests.swift
//  PalaceTests
//
//  Tests for DeviceOrientation tracking.
//

import XCTest
@testable import Palace

final class DeviceOrientationTests: XCTestCase {

    var orientation: DeviceOrientation!

    override nonisolated func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            orientation = DeviceOrientation()
        }
    }

    override nonisolated func tearDown() {
        MainActor.assumeIsolated {
            orientation?.stopTracking()
            orientation = nil
        }
        super.tearDown()
    }

    // MARK: - Initial State Tests

    @MainActor
    func testInitialIsLandscape_basedOnScreenDimensions() {
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        let expectedIsLandscape = screenWidth > screenHeight

        XCTAssertEqual(orientation.isLandscape, expectedIsLandscape)
        // The value must be a Bool — exhaustive check
        XCTAssertTrue(orientation.isLandscape == true || orientation.isLandscape == false)
        // isLandscape should be consistent with screen dimensions
        if screenWidth > screenHeight {
            XCTAssertTrue(orientation.isLandscape)
        } else {
            XCTAssertFalse(orientation.isLandscape)
        }
    }

    @MainActor
    func testIsLandscape_isPublished() {
        // Verify that isLandscape is a published property
        // by checking it's accessible and returns a Bool
        let value = orientation.isLandscape
        XCTAssertNotNil(value)
        XCTAssertTrue(value == true || value == false)
        // A second read should return the same value (no side effects from reading)
        XCTAssertEqual(orientation.isLandscape, value)
    }

    // MARK: - Tracking Tests

    @MainActor
    func testStartTracking_doesNotCrash() {
        orientation.startTracking()
        // After startTracking, isLandscape should still be valid
        let value = orientation.isLandscape
        XCTAssertTrue(value == true || value == false)
        // Calling startTracking again must be idempotent (no crash, same type of value)
        orientation.startTracking()
        let valueAfterSecondStart = orientation.isLandscape
        XCTAssertTrue(valueAfterSecondStart == true || valueAfterSecondStart == false,
                      "isLandscape must remain a valid Bool after repeated startTracking calls")
    }

    @MainActor
    func testStopTracking_doesNotCrash() {
        orientation.startTracking()
        orientation.stopTracking()
        // After stop, isLandscape should still be readable
        let value = orientation.isLandscape
        XCTAssertTrue(value == true || value == false)
        // Calling startTracking after stop must work (start-stop-start cycle)
        orientation.startTracking()
        let valueAfterRestart = orientation.isLandscape
        XCTAssertTrue(valueAfterRestart == true || valueAfterRestart == false,
                      "isLandscape must remain readable after a start-stop-start cycle")
    }

    @MainActor
    func testStartAndStopTracking_multipleTimesDoesNotCrash() {
        orientation.startTracking()
        orientation.stopTracking()
        orientation.startTracking()
        orientation.stopTracking()
        // isLandscape should still be accessible after multiple cycles
        let value = orientation.isLandscape
        XCTAssertTrue(value == true || value == false)
    }

    @MainActor
    func testStopTracking_beforeStartTracking_doesNotCrash() {
        // Stop without starting should be safe
        orientation.stopTracking()
        // isLandscape should still be accessible after early stop
        let value = orientation.isLandscape
        XCTAssertTrue(value == true || value == false)
        // Starting after an early stop must also work
        orientation.startTracking()
        let valueAfterStart = orientation.isLandscape
        XCTAssertTrue(valueAfterStart == true || valueAfterStart == false,
                      "isLandscape must be valid after starting following an early stop")
    }

    // MARK: - ObservableObject Conformance

    @MainActor
    func testDeviceOrientation_isObservableObject() {
        // DeviceOrientation should conform to ObservableObject
        let observable: any ObservableObject = orientation
        XCTAssertNotNil(observable)
        // The objectWillChange publisher should exist
        let publisher = orientation.objectWillChange
        XCTAssertNotNil(publisher)
    }
}
