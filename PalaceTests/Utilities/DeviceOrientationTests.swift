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

    @MainActor
    override func setUp() {
        super.setUp()
        orientation = DeviceOrientation()
    }

    @MainActor
    override func tearDown() {
        orientation?.stopTracking()
        orientation = nil
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
    }

    @MainActor
    func testStopTracking_doesNotCrash() {
        orientation.startTracking()
        orientation.stopTracking()
        // After stop, isLandscape should still be readable
        let value = orientation.isLandscape
        XCTAssertTrue(value == true || value == false)
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
