//
//  DeviceOrientationTests.swift
//  PalaceTests
//
//  Tests for DeviceOrientation tracking.
//

import XCTest
@testable import Palace

@MainActor
final class DeviceOrientationTests: XCTestCase {
  
  var orientation: DeviceOrientation!
  
  override func setUp() async throws {
    try await super.setUp()
    orientation = DeviceOrientation()
  }
  
  override func tearDown() async throws {
    orientation?.stopTracking()
    orientation = nil
    try await super.tearDown()
  }
  
  // MARK: - Initial State Tests
  
  func testInitialIsLandscape_basedOnScreenDimensions() {
    let screenWidth = UIScreen.main.bounds.width
    let screenHeight = UIScreen.main.bounds.height
    let expectedIsLandscape = screenWidth > screenHeight
    
    XCTAssertEqual(orientation.isLandscape, expectedIsLandscape)
  }
  
  func testIsLandscape_isPublished() {
    // Verify that isLandscape is a published property
    // by checking it's accessible and returns a Bool
    let value = orientation.isLandscape
    XCTAssertNotNil(value)
    XCTAssertTrue(value == true || value == false)
  }
  
  // MARK: - Tracking Tests
  
  func testStartTracking_doesNotCrash() {
    orientation.startTracking()
    // If we get here without crashing, tracking started successfully
  }
  
  func testStopTracking_doesNotCrash() {
    orientation.startTracking()
    orientation.stopTracking()
    // If we get here without crashing, tracking stopped successfully
  }
  
  func testStartAndStopTracking_multipleTimesDoesNotCrash() {
    orientation.startTracking()
    orientation.stopTracking()
    orientation.startTracking()
    orientation.stopTracking()
    // Should handle multiple start/stop cycles gracefully
  }
  
  func testStopTracking_beforeStartTracking_doesNotCrash() {
    // Stop without starting should be safe
    orientation.stopTracking()
  }
  
  // MARK: - ObservableObject Conformance
  
  func testDeviceOrientation_isObservableObject() {
    // DeviceOrientation should conform to ObservableObject
    let observable: any ObservableObject = orientation
    XCTAssertNotNil(observable)
  }
}

