//
//  TPPPresentationUtils.swift
//  The Palace Project / Open eBooks
//
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

/// Transports a non-`Sendable` UIKit payload (a view controller plus an
/// optional completion handler) across a `DispatchQueue.main.async` boundary.
/// Every dispatch target in `safelyPresent` is `DispatchQueue.main`, so the
/// boxed values are only ever created on and consumed on the main actor — the
/// transfer is data-race-free even though the payload is not `Sendable`.
private final class MainActorPresentation: @unchecked Sendable {
    let viewController: UIViewController
    let completion: (() -> Void)?
    let rootProvider: @MainActor () -> UIViewController?
    init(_ viewController: UIViewController,
         _ completion: (() -> Void)?,
         _ rootProvider: @escaping @MainActor () -> UIViewController?) {
        self.viewController = viewController
        self.completion = completion
        self.rootProvider = rootProvider
    }
}

class TPPPresentationUtils: NSObject {
    /// How often a presentation queued behind a visible alert re-checks
    /// whether the alert has been dismissed.
    static let alertDismissalPollInterval: TimeInterval = 0.25

    /// Presents the given view controller on top of the topmost currently
    /// displayed view controller in the current window.
    ///
    /// This function does not assume anything regarding the current view
    /// controller. In particular, it does _not_ assume that it is the
    /// `NYPLRootTabBarController::shared` instance.
    ///
    /// If the input and topmost view controllers are both
    /// UINavigationControllers, this method bails presentation if they
    /// both contain a first view controller of the same type.
    ///
    /// If the topmost view controller is a `UIAlertController`, presentation
    /// waits until that alert is dismissed (PP-5348).
    ///
    /// - Parameters:
    ///   - vc: The view controller to be presented.
    ///   - animated: Whether to animate the presentation of not.
    ///   - completion: Completion handler to be called when the presentation ends.
    @objc class func safelyPresent(_ vc: UIViewController,
                                   animated: Bool = true,
                                   completion: (() -> Void)? = nil) {
        safelyPresent(vc, animated: animated, completion: completion,
                      rootProvider: { appWindowRootViewController() })
    }

    /// Same as `safelyPresent(_:animated:completion:)`, with the root view
    /// controller supplied by `rootProvider` so tests can use their own window.
    class func safelyPresent(_ vc: UIViewController,
                             animated: Bool,
                             completion: (() -> Void)?,
                             rootProvider: @escaping @MainActor () -> UIViewController?) {
        // Box the non-`Sendable` UIKit payload ONCE, here in the nonisolated
        // function region, before any `@Sendable` boundary. Every downstream use
        // (the off-main hop, the coordinator completion, the nested main.async)
        // reads `payload.viewController` / `payload.completion` from the
        // `@unchecked Sendable` carrier rather than re-capturing `vc`/`completion`
        // directly — which is what produced the "sending 'completion' risks data
        // races" diagnostic when the box was rebuilt inside `assumeIsolated`.
        let payload = MainActorPresentation(vc, completion, rootProvider)

        // Ensure this block is always executed on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                safelyPresent(payload.viewController, animated: animated, completion: payload.completion,
                              rootProvider: payload.rootProvider)
            }
            return
        }

        // Past the guard above we are provably on the main thread, so it is safe
        // to assert main-actor isolation for the UIKit work below rather than
        // hopping again.
        MainActor.assumeIsolated {
            guard var base = payload.rootProvider() else {
                return
            }

            while true {
                guard let topBase = base.presentedViewController else {
                    break
                }
                base = topBase
            }

            // A UIAlertController cannot present. Presenting from one throws
            // "A view controller not containing an alert controller was asked
            // for its contained alert controller" from UIKit's deferred
            // CA-commit block, where no catcher can reach it (Crashlytics
            // fe741015, PP-5348: the sign-in sheet raised by a refused token
            // refresh at launch, over a visible alert). Wait for the alert to
            // be dismissed, then walk the hierarchy again.
            if base is UIAlertController {
                DispatchQueue.main.asyncAfter(deadline: .now() + alertDismissalPollInterval) {
                    safelyPresent(payload.viewController, animated: animated, completion: payload.completion,
                                  rootProvider: payload.rootProvider)
                }
                return
            }

            if let baseNavController = base as? UINavigationController,
               let inputNavController = payload.viewController as? UINavigationController,
               baseNavController.viewControllers.count == inputNavController.viewControllers.count,
               let baseVC = baseNavController.viewControllers.first,
               let inputVC = inputNavController.viewControllers.first {

                if type(of: baseVC) == type(of: inputVC) {
                    return
                }
            }

            // If a presentation/dismiss/push is already in flight on `base`,
            // calling present() here is the failure mode behind the SAML re-auth
            // lock-up: UIKit rejects the present with "transitioning already",
            // leaves the form sheet half-mounted, and the app freezes. Wait for
            // the in-flight transition to complete, then re-walk to the (possibly
            // new) topmost VC and present there. HelpSpot 17716 follow-up.
            if let coordinator = base.transitionCoordinator {
                // Only the `@unchecked Sendable` `payload` carrier (built once at
                // function entry) crosses the escaping coordinator completion —
                // `vc`/`completion` themselves never cross. The box is built, and
                // later read, only on the main actor (both the coordinator
                // completion and the nested main.async run on main), so the
                // transfer is data-race-free. Dispatch structure unchanged.
                coordinator.animate(alongsideTransition: nil) { _ in
                    DispatchQueue.main.async {
                        safelyPresent(payload.viewController, animated: animated, completion: payload.completion,
                                      rootProvider: payload.rootProvider)
                    }
                }
                return
            }

            base.present(payload.viewController, animated: animated, completion: payload.completion)
        }
    }

    /// The app window's root view controller; logs when there is none.
    @MainActor
    private class func appWindowRootViewController() -> UIViewController? {
        let delegate = UIApplication.shared.delegate
        guard let root = delegate?.window??.rootViewController else {
            TPPErrorLogger.logError(withCode: .missingExpectedObject,
                                    summary: "Unable to find rootViewController",
                                    metadata: [
                                        "DelegateIsNil": (delegate == nil),
                                        "WindowIsNil": (delegate?.window == nil)
                                    ])
            return nil
        }
        return root
    }
}
