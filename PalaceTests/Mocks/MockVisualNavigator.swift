//
//  MockVisualNavigator.swift
//  PalaceTests
//
//  Mock implementation of VisualNavigator for testing keyboard navigation.
//  Used for keyboard accessibility testing.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
@testable import Palace
import ReadiumNavigator
import ReadiumShared

/// Mock implementation of VisualNavigator for testing keyboard navigation
@MainActor
final class MockVisualNavigator: NSObject, VisualNavigator {

    // MARK: - Call Tracking

    /// Tracks whether goLeft was called
    private(set) var didCallGoLeft = false

    /// Tracks whether goRight was called
    private(set) var didCallGoRight = false

    /// Tracks whether goForward was called
    private(set) var didCallGoForward = false

    /// Tracks whether goBackward was called
    private(set) var didCallGoBackward = false

    /// Tracks the number of times each method was called
    private(set) var goLeftCallCount = 0
    private(set) var goRightCallCount = 0
    private(set) var goForwardCallCount = 0
    private(set) var goBackwardCallCount = 0

    // MARK: - Configuration

    /// Whether navigation calls should return success
    var navigationSucceeds = true

    /// Mock presentation for testing reading progression
    var mockPresentation = VisualNavigatorPresentation(
        readingProgression: .ltr,
        scroll: false,
        axis: .horizontal
    )

    // MARK: - Reset

    /// Resets all tracking state
    func reset() {
        didCallGoLeft = false
        didCallGoRight = false
        didCallGoForward = false
        didCallGoBackward = false
        goLeftCallCount = 0
        goRightCallCount = 0
        goForwardCallCount = 0
        goBackwardCallCount = 0
    }

    // MARK: - Navigator Protocol

    var publication: Publication {
        // Return a minimal mock publication
        fatalError("Publication not needed for keyboard navigation tests")
    }

    var currentLocation: Locator? { nil }

    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        navigationSucceeds
    }

    func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        navigationSucceeds
    }

    func goForward(options: NavigatorGoOptions) async -> Bool {
        didCallGoForward = true
        goForwardCallCount += 1
        return navigationSucceeds
    }

    func goBackward(options: NavigatorGoOptions) async -> Bool {
        didCallGoBackward = true
        goBackwardCallCount += 1
        return navigationSucceeds
    }

    // MARK: - VisualNavigator Protocol

    var view: UIView! { UIView() }

    var presentation: VisualNavigatorPresentation { mockPresentation }

    func goLeft(options: NavigatorGoOptions) async -> Bool {
        didCallGoLeft = true
        goLeftCallCount += 1
        return navigationSucceeds
    }

    func goRight(options: NavigatorGoOptions) async -> Bool {
        didCallGoRight = true
        goRightCallCount += 1
        return navigationSucceeds
    }

    func firstVisibleElementLocator() async -> Locator? { nil }

    // MARK: - InputObservable Protocol

    private var inputObservers: [InputObservableToken: InputObserving] = [:]

    @discardableResult
    func addObserver(_ observer: InputObserving) -> InputObservableToken {
        let token = InputObservableToken()
        inputObservers[token] = observer
        return token
    }

    func removeObserver(_ token: InputObservableToken) {
        inputObservers.removeValue(forKey: token)
    }
}
