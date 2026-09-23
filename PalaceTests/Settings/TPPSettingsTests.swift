//
//  TPPSettingsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
import Combine
@testable import Palace

@MainActor
final class TPPSettingsTests: XCTestCase {

    private var settings: TPPSettings!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        settings = TPPSettings()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Setter Early-Return Guard (mutation surface)

    /// Setting `customMainFeedURL` to its current value must skip the
    /// notification post — the setter has an explicit early-return guard
    /// to avoid spurious change events. Mutating that guard would be silently
    /// undetected without this test.
    func testCustomMainFeedURL_setToSameValue_doesNotPostNotification() {
        let url = URL(string: "https://example.com/feed-\(UUID().uuidString)")!
        let original = settings.customMainFeedURL
        settings.customMainFeedURL = url
        defer { settings.customMainFeedURL = original }

        var notificationCount = 0
        // Scope the observer to THIS instance — TPPSettings is no longer a
        // singleton (8836c3263), so other code paths (parallel tests, the
        // production AppContainer's own settings instance) can also post
        // `.TPPSettingsDidChange` during the drain window. `object: nil`
        // would catch those and inflate the count, producing a CI flake
        // that doesn't reflect this setter's guard at all.
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.TPPSettingsDidChange,
            object: settings,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Re-set to the same value — should NOT post.
        settings.customMainFeedURL = url

        // Drain the run loop to allow any errant posts to land.
        let drained = expectation(description: "drain run loop")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(notificationCount, 0,
                       "Setting customMainFeedURL to its current value must not post TPPSettingsDidChange")
    }

    /// Same guard for `accountMainFeedURL`.
    func testAccountMainFeedURL_setToSameValue_doesNotPostNotification() {
        let url = URL(string: "https://example.com/account-\(UUID().uuidString)")!
        let original = settings.accountMainFeedURL
        settings.accountMainFeedURL = url
        defer { settings.accountMainFeedURL = original }

        var notificationCount = 0
        // See sibling `testCustomMainFeedURL_setToSameValue...` for why we
        // scope to `object: settings` instead of `nil` — TPPSettings is no
        // longer a singleton, and `object: nil` catches notifications from
        // every other TPPSettings instance in the process, including the
        // production AppContainer's.
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.TPPSettingsDidChange,
            object: settings,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.accountMainFeedURL = url

        let drained = expectation(description: "drain run loop")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(notificationCount, 0,
                       "Setting accountMainFeedURL to its current value must not post TPPSettingsDidChange")
    }

    /// Setting `customMainFeedURL` to a *different* value must post the
    /// notification — verifies the change-detection branch.
    func testCustomMainFeedURL_setToDifferentValue_postsNotification() {
        let oldURL = URL(string: "https://example.com/old-\(UUID().uuidString)")!
        let newURL = URL(string: "https://example.com/new-\(UUID().uuidString)")!
        let original = settings.customMainFeedURL
        settings.customMainFeedURL = oldURL
        defer { settings.customMainFeedURL = original }

        let posted = expectation(description: "TPPSettingsDidChange posted")
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.TPPSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.customMainFeedURL = newURL

        wait(for: [posted], timeout: 2.0)
    }

    // MARK: - Combine Publishers

    /// `useBetaLibraries` setter must publish via the `useBetaDidChange` Combine
    /// subject. Replaces the legacy `.TPPUseBetaDidChange` notification observers.
    func testUseBetaLibraries_publishesViaCombine() {
        let original = settings.useBetaLibraries
        defer { settings.useBetaLibraries = original }

        let received = expectation(description: "useBetaDidChange published")
        var capturedValue: Bool?

        settings.useBetaDidChange
            .sink { value in
                capturedValue = value
                received.fulfill()
            }
            .store(in: &cancellables)

        settings.useBetaLibraries = !original

        wait(for: [received], timeout: 2.0)
        XCTAssertEqual(capturedValue, !original,
                       "Combine publisher must emit the new value")
    }

    /// `customMainFeedURL` setter must publish via the omnibus `settingsDidChange`
    /// publisher (which replaces direct `.TPPSettingsDidChange` notification observation).
    func testCustomMainFeedURL_publishesViaSettingsDidChange() {
        let original = settings.customMainFeedURL
        let newURL = URL(string: "https://example.com/combine-\(UUID().uuidString)")!
        defer { settings.customMainFeedURL = original }

        let received = expectation(description: "settingsDidChange published")
        settings.settingsDidChange
            .sink { _ in received.fulfill() }
            .store(in: &cancellables)

        settings.customMainFeedURL = newURL

        wait(for: [received], timeout: 2.0)
    }

    // MARK: - Notifications

    func testUseBetaLibraries_postsNotification() {
        let original = settings.useBetaLibraries
        defer { settings.useBetaLibraries = original }

        let posted = expectation(description: "TPPUseBetaDidChange posted")
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.TPPUseBetaDidChange,
            object: nil,
            queue: .main
        ) { _ in
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.useBetaLibraries = !original

        wait(for: [posted], timeout: 2.0)
    }
}
