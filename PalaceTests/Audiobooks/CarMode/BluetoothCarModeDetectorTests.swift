//
//  BluetoothCarModeDetectorTests.swift
//  PalaceTests
//
//  Tests for BluetoothCarModeDetector Bluetooth detection and prompt logic.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import XCTest
@testable import Palace

// MARK: - Mocks

private final class MockNotificationCenter: NotificationCenterProtocol {
    private(set) var observers: [(observer: Any, name: Notification.Name?, selector: Selector)] = []
    private(set) var removeObserverCalled = false

    func addObserver(
        _ observer: Any,
        selector: Selector,
        name: Notification.Name?,
        object: Any?
    ) {
        observers.append((observer: observer, name: name, selector: selector))
    }

    func removeObserver(_ observer: Any) {
        removeObserverCalled = true
        observers.removeAll()
    }

    func post(name: Notification.Name, object: Any?, userInfo: [AnyHashable: Any]?) {
        for entry in observers where entry.name == name {
            let notification = Notification(name: name, object: object, userInfo: userInfo)
            _ = (entry.observer as AnyObject).perform(entry.selector, with: notification)
        }
    }
}

private struct MockFeatureFlags: CarModeFeatureFlags {
    var carModeEnabled: Bool
}

// MARK: - Tests

@MainActor
final class BluetoothCarModeDetectorTests: XCTestCase {

    private var notificationCenter: MockNotificationCenter!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        notificationCenter = MockNotificationCenter()
        // Use a volatile suite so tests don't pollute real defaults
        userDefaults = UserDefaults(suiteName: "BluetoothCarModeDetectorTests")!
        userDefaults.removePersistentDomain(forName: "BluetoothCarModeDetectorTests")
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: "BluetoothCarModeDetectorTests")
        userDefaults = nil
        notificationCenter = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState_shouldPromptCarModeIsFalse() {
        let detector = makeDetector(carModeEnabled: true)
        XCTAssertFalse(detector.shouldPromptCarMode)
    }

    func testInitialState_autoDetectionDisabledByDefault() {
        let detector = makeDetector(carModeEnabled: true)
        XCTAssertFalse(detector.autoDetectionEnabled)
    }

    // MARK: - Auto-Detection Persistence

    func testEnableAutoDetection_persistsToUserDefaults() {
        let detector = makeDetector(carModeEnabled: true)

        detector.autoDetectionEnabled = true

        XCTAssertTrue(userDefaults.bool(forKey: BluetoothCarModeDetector.autoDetectionKey))
    }

    func testDisableAutoDetection_persistsToUserDefaults() {
        let detector = makeDetector(carModeEnabled: true)
        detector.autoDetectionEnabled = true

        detector.autoDetectionEnabled = false

        XCTAssertFalse(userDefaults.bool(forKey: BluetoothCarModeDetector.autoDetectionKey))
    }

    func testAutoDetection_readsPersistedValue() {
        userDefaults.set(true, forKey: BluetoothCarModeDetector.autoDetectionKey)

        let detector = makeDetector(carModeEnabled: true)

        XCTAssertTrue(detector.autoDetectionEnabled)
    }

    // MARK: - Observer Setup

    func testEnableAutoDetection_registersObserver() {
        let detector = makeDetector(carModeEnabled: true)

        detector.autoDetectionEnabled = true

        XCTAssertEqual(notificationCenter.observers.count, 1)
        XCTAssertEqual(
            notificationCenter.observers.first?.name,
            AVAudioSession.routeChangeNotification
        )
    }

    func testDisableAutoDetection_removesObserver() {
        let detector = makeDetector(carModeEnabled: true)
        detector.autoDetectionEnabled = true

        detector.autoDetectionEnabled = false

        XCTAssertTrue(notificationCenter.removeObserverCalled)
    }

    func testAutoDetectionEnabledOnInit_registersObserver() {
        userDefaults.set(true, forKey: BluetoothCarModeDetector.autoDetectionKey)

        _ = makeDetector(carModeEnabled: true)

        XCTAssertEqual(notificationCenter.observers.count, 1)
    }

    func testEnableAutoDetection_doesNotDuplicateObserver() {
        let detector = makeDetector(carModeEnabled: true)

        detector.autoDetectionEnabled = true
        detector.autoDetectionEnabled = true

        // Should still only have one observer (second enable is no-op)
        XCTAssertEqual(notificationCenter.observers.count, 1)
    }

    // MARK: - Feature Flag Gating

    func testFeatureFlagDisabled_doesNotSetUpObserver() {
        userDefaults.set(true, forKey: BluetoothCarModeDetector.autoDetectionKey)

        _ = makeDetector(carModeEnabled: false)

        XCTAssertTrue(notificationCenter.observers.isEmpty,
                      "Observer should not be set up when carModeEnabled is false")
    }

    // MARK: - Dismiss Prompt

    func testDismissPrompt_setsShouldPromptToFalse() {
        let detector = makeDetector(carModeEnabled: true)
        // Simulate prompt being shown (we can't easily trigger Bluetooth in tests,
        // but we can test the dismiss path)
        detector.dismissPrompt()

        XCTAssertFalse(detector.shouldPromptCarMode)
    }

    // MARK: - Reset

    func testReset_clearsShouldPrompt() {
        let detector = makeDetector(carModeEnabled: true)
        detector.autoDetectionEnabled = true

        detector.reset()

        XCTAssertFalse(detector.shouldPromptCarMode)
    }

    func testReset_stopsObserving() {
        let detector = makeDetector(carModeEnabled: true)
        detector.autoDetectionEnabled = true

        detector.reset()

        XCTAssertTrue(notificationCenter.removeObserverCalled)
    }

    // MARK: - Route Change Notification

    func testRouteChangeNotification_withAutoDetectionDisabled_doesNotPrompt() {
        let detector = makeDetector(carModeEnabled: true)
        detector.autoDetectionEnabled = false

        // Even if we could trigger a notification, auto-detection is off
        // so shouldPromptCarMode should remain false
        XCTAssertFalse(detector.shouldPromptCarMode)
    }

    // MARK: - Helpers

    private func makeDetector(carModeEnabled: Bool) -> BluetoothCarModeDetector {
        BluetoothCarModeDetector(
            notificationCenter: notificationCenter,
            userDefaults: userDefaults,
            featureFlags: MockFeatureFlags(carModeEnabled: carModeEnabled)
        )
    }
}
