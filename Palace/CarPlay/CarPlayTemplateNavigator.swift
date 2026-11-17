//
//  CarPlayTemplateNavigator.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import CarPlay
import PalaceLogging

/// The slice of `CPInterfaceController` that `CarPlayTemplateNavigator` drives.
/// `CPInterfaceController` cannot be constructed in a unit test, so the
/// navigator depends on this protocol and tests supply a fake that follows the
/// same contract.
@MainActor
protocol CarPlayTemplateNavigating: AnyObject {
    var topTemplate: CPTemplate? { get }
    var templates: [CPTemplate] { get }
    var presentedTemplate: CPTemplate? { get }
    func setRootTemplate(_ rootTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func pushTemplate(_ templateToPush: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func popTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func popToRootTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func presentTemplate(_ templateToPresent: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func dismissTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
}

extension CPInterfaceController: CarPlayTemplateNavigating {}

/// Issues every CarPlay template operation Palace performs, always with a
/// completion handler. No method here accepts a completion to forward, so a
/// caller cannot pass `nil` through to CarPlay.
///
/// `CPInterfaceController` raises `NSGenericException` ("An error was
/// encountered during a template operation, but no completion block was
/// specified") when an operation fails and its completion is nil (PP-5276).
/// Failures here are expected: stack changes apply asynchronously, so a burst
/// of playback errors can queue several pops of Now Playing before the first
/// lands, and the system can close Now Playing itself when playback fails.
/// Crashlytics 81c394a96d71333a4f8e8ad0dca4d700 records both "No templates
/// were available to be popped" and "Attempting to push a template without a
/// root template" raised this way. The completion turns each into a log line.
///
/// The controller is held weakly. Once it is gone every operation is a no-op
/// and `then` is not called.
@MainActor
final class CarPlayTemplateNavigator {
    /// Runs after CarPlay reports the outcome; `error` is nil on success.
    typealias Outcome = (_ error: (any Error)?) -> Void

    private weak var controller: CarPlayTemplateNavigating?
    private let isNowPlaying: (CPTemplate) -> Bool

    init(
        controller: CarPlayTemplateNavigating,
        isNowPlaying: @escaping (CPTemplate) -> Bool = { $0 is CPNowPlayingTemplate }
    ) {
        self.controller = controller
        self.isNowPlaying = isNowPlaying
    }

    // MARK: Stack state

    var isAttached: Bool { controller != nil }

    /// Number of templates on the navigation stack, or nil once the controller is gone.
    var templateCount: Int? { controller?.templates.count }

    var hasPresentedTemplate: Bool { controller?.presentedTemplate != nil }

    var isNowPlayingOnTop: Bool {
        guard let top = controller?.topTemplate else { return false }
        return isNowPlaying(top)
    }

    // MARK: Operations

    func setRoot(_ template: CPTemplate, operation: String, then: Outcome? = nil) {
        controller?.setRootTemplate(template, animated: true, completion: Self.completion(operation, then))
    }

    func push(_ template: CPTemplate, operation: String, then: Outcome? = nil) {
        controller?.pushTemplate(template, animated: true, completion: Self.completion(operation, then))
    }

    func pop(operation: String) {
        controller?.popTemplate(animated: true, completion: Self.completion(operation, nil))
    }

    /// Pops to the root template when anything is stacked above it.
    func popToRootIfStacked() {
        guard let controller, controller.templates.count > 1 else { return }
        controller.popToRootTemplate(animated: false, completion: Self.completion("popToRootTemplate", nil))
    }

    func present(_ template: CPTemplate, operation: String, then: Outcome? = nil) {
        controller?.presentTemplate(template, animated: true, completion: Self.completion(operation, then))
    }

    func dismiss(operation: String, then: Outcome? = nil) {
        controller?.dismissTemplate(animated: true, completion: Self.completion(operation, then))
    }

    /// Pops Now Playing back to the library after a playback error.
    func popNowPlayingIfOnTop() {
        guard let controller, isNowPlayingOnTop else { return }
        controller.popTemplate(animated: true, completion: Self.completion("popTemplate(nowPlaying)", nil))
    }

    private static func completion(_ operation: String, _ then: Outcome?) -> (Bool, (any Error)?) -> Void {
        { _, error in
            if let error {
                Log.warn(#file, "CarPlay: \(operation) failed: \(error)")
            }
            then?(error)
        }
    }
}
