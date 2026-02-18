//
//  KeyboardNavigationHandler.swift
//  Palace
//
//  Handles keyboard events for EPUB reader navigation.
//  Implements iOS keyboard accessibility controls.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumNavigator

/// Protocol defining keyboard navigation capabilities for the reader
@MainActor
protocol KeyboardNavigable: AnyObject {
    /// Whether the navigation bar (toolbar) is currently hidden
    var isToolbarHidden: Bool { get }

    /// Toggles the toolbar visibility
    func toggleToolbar()

    /// Navigates to the left page
    func navigateLeft() async -> Bool

    /// Navigates to the right page
    func navigateRight() async -> Bool

    /// Navigates forward in reading progression
    func navigateForward() async -> Bool
}

/// Handles keyboard events for EPUB reader navigation.
/// Single authoritative handler — GCKeyboard events are routed through here
/// to get throttling and concurrent-navigation protection.
@MainActor
final class KeyboardNavigationHandler {

    // MARK: - Properties

    private weak var navigable: KeyboardNavigable?

    /// Closure that returns whether iOS Full Keyboard Access is enabled.
    /// When FKA is on, arrow keys are skipped (FKA uses them for focus navigation)
    /// but Space/PageUp/PageDown/Escape are still handled.
    private let isFullKeyboardAccessEnabled: () -> Bool

    /// Track if navigation is currently in progress to prevent overlapping navigations
    private var isNavigating: Bool = false

    /// Throttle interval to prevent rapid-fire GCKeyboard repeats
    private let throttleInterval: TimeInterval = 0.25

    /// Timestamp of last navigation action
    private var lastNavigationTime: CFAbsoluteTime = 0

    // MARK: - Initialization

    init(navigable: KeyboardNavigable,
         isFullKeyboardAccessEnabled: @escaping () -> Bool = { false }) {
        self.navigable = navigable
        self.isFullKeyboardAccessEnabled = isFullKeyboardAccessEnabled
    }

    // MARK: - Keyboard Event Handling

    /// Handles a keyboard event from the navigator
    /// - Parameter event: The key event to handle
    /// - Returns: Whether the event was consumed
    @discardableResult
    func handleKeyEvent(_ event: KeyEvent) async -> Bool {
        // Only handle key down events
        guard event.phase == .down else { return false }

        // Ignore events with modifiers (allow system shortcuts like Cmd+C)
        guard event.modifiers.isEmpty else { return false }

        guard let navigable = navigable else { return false }

        let fkaEnabled = isFullKeyboardAccessEnabled()

        switch event.key {
        case .escape:
            navigable.toggleToolbar()
            return true

        case .arrowLeft:
            // When FKA is enabled, skip arrow keys — let FKA use them for focus navigation
            guard !fkaEnabled else { return false }
            guard navigable.isToolbarHidden else { return false }
            return await performNavigation { await navigable.navigateLeft() }

        case .arrowRight:
            guard !fkaEnabled else { return false }
            guard navigable.isToolbarHidden else { return false }
            return await performNavigation { await navigable.navigateRight() }

        case .space:
            guard navigable.isToolbarHidden else { return false }
            return await performNavigation { await navigable.navigateForward() }

        case .pageDown:
            guard navigable.isToolbarHidden else { return false }
            return await performNavigation { await navigable.navigateForward() }

        case .pageUp:
            guard navigable.isToolbarHidden else { return false }
            return await performNavigation { await navigable.navigateLeft() }

        default:
            return false
        }
    }

    /// Handles a ReaderKeyboardCommand (from GCKeyboard/pressesBegan via KeyboardInputMapper).
    /// Provides throttling and concurrent-navigation protection.
    func handleCommand(_ command: TPPBaseReaderViewController.ReaderKeyboardCommand,
                       via navigable: KeyboardNavigable) async {
        // Throttle: ignore if too soon after last navigation
        let now = CFAbsoluteTimeGetCurrent()
        guard !isNavigating, (now - lastNavigationTime) >= throttleInterval else { return }

        isNavigating = true
        lastNavigationTime = now

        switch command {
        case .goBackward:
            _ = await navigable.navigateLeft()
        case .goForward:
            _ = await navigable.navigateRight()
        case .toggleUI:
            navigable.toggleToolbar()
        }

        isNavigating = false
    }

    // MARK: - Private Helpers

    /// Perform navigation with in-progress tracking and throttling
    private func performNavigation(_ action: @escaping () async -> Bool) async -> Bool {
        let now = CFAbsoluteTimeGetCurrent()

        // Prevent concurrent navigation
        guard !isNavigating else {
            return true // Consume the event but don't navigate
        }

        // Throttle rapid-fire repeats
        guard (now - lastNavigationTime) >= throttleInterval else {
            return true // Consume the event but don't navigate
        }

        isNavigating = true
        lastNavigationTime = now
        let result = await action()
        isNavigating = false

        return result
    }
}
