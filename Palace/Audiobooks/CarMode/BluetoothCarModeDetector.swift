//
//  BluetoothCarModeDetector.swift
//  Palace
//
//  Monitors AVAudioSession route changes and offers to enter car mode
//  when Bluetooth audio (car stereo) connects.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation
import UserNotifications

// MARK: - BluetoothCarModeDetector

@MainActor
public final class BluetoothCarModeDetector: ObservableObject {

    // MARK: - Published State

    /// When true, the detector has determined Bluetooth audio connected
    /// and the user should be prompted to enter car mode.
    @Published public private(set) var shouldPromptCarMode: Bool = false

    /// User preference: auto-prompt car mode on Bluetooth connect.
    @Published public var isAutoDetectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoDetectionEnabled, forKey: Self.autoDetectionKey)
        }
    }

    // MARK: - Configuration

    private static let autoDetectionKey = "carMode.autoDetectBluetooth"

    // MARK: - Properties

    private var cancellables = Set<AnyCancellable>()
    private let notificationCenter: NotificationCenter

    // MARK: - Initialization

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        self.isAutoDetectionEnabled = UserDefaults.standard.bool(forKey: Self.autoDetectionKey)
        // Only observe Bluetooth if Car Mode feature is enabled
        guard RemoteFeatureFlags.shared.isFeatureEnabled(.carModeEnabled) else { return }
        setupRouteChangeObserver()
        Log.info(#file, "BluetoothCarModeDetector initialized (autoDetect: \(isAutoDetectionEnabled))")
    }

    // MARK: - Public API

    /// Dismisses the car mode prompt.
    public func dismissPrompt() {
        shouldPromptCarMode = false
    }

    /// Resets the detector state (e.g., when exiting car mode).
    public func reset() {
        shouldPromptCarMode = false
    }

    // MARK: - Private Methods

    private func setupRouteChangeObserver() {
        notificationCenter
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleRouteChange(notification)
            }
            .store(in: &cancellables)
    }

    private func handleRouteChange(_ notification: Notification) {
        guard isAutoDetectionEnabled else { return }

        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            checkForBluetoothAudio()

        case .oldDeviceUnavailable:
            // Bluetooth disconnected - dismiss any active prompt
            shouldPromptCarMode = false

        default:
            break
        }
    }

    private func checkForBluetoothAudio() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs

        let hasBluetoothOutput = outputs.contains { output in
            output.portType == .bluetoothA2DP
                || output.portType == .bluetoothHFP
                || output.portType == .bluetoothLE
                || output.portType == .carAudio
        }

        if hasBluetoothOutput {
            Log.info(#file, "Bluetooth audio detected - prompting car mode")
            shouldPromptCarMode = true
            sendBackgroundNotificationIfNeeded()
        }
    }

    private func sendBackgroundNotificationIfNeeded() {
        let app = UIApplication.shared
        guard app.applicationState == .background else { return }

        let content = UNMutableNotificationContent()
        content.title = "Car Audio Connected"
        content.body = "Tap to open Car Mode for easy audiobook control while driving."
        content.sound = .default
        content.categoryIdentifier = "carModePrompt"

        let request = UNNotificationRequest(
            identifier: "carModeBluetoothPrompt",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.error(#file, "Failed to schedule car mode notification: \(error)")
            } else {
                Log.debug(#file, "Car mode background notification scheduled")
            }
        }
    }
}
