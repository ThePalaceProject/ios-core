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
    init(_ viewController: UIViewController, _ completion: (() -> Void)?) {
        self.viewController = viewController
        self.completion = completion
    }
}

class TPPPresentationUtils: NSObject {
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
    /// - Parameters:
    ///   - vc: The view controller to be presented.
    ///   - animated: Whether to animate the presentation of not.
    ///   - completion: Completion handler to be called when the presentation ends.
    @objc class func safelyPresent(_ vc: UIViewController,
                                   animated: Bool = true,
                                   completion: (() -> Void)? = nil) {
        // Box the non-`Sendable` UIKit payload ONCE, here in the nonisolated
        // function region, before any `@Sendable` boundary. Every downstream use
        // (the off-main hop, the coordinator completion, the nested main.async)
        // reads `payload.viewController` / `payload.completion` from the
        // `@unchecked Sendable` carrier rather than re-capturing `vc`/`completion`
        // directly — which is what produced the "sending 'completion' risks data
        // races" diagnostic when the box was rebuilt inside `assumeIsolated`.
        let payload = MainActorPresentation(vc, completion)

        // Ensure this block is always executed on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                safelyPresent(payload.viewController, animated: animated, completion: payload.completion)
            }
            return
        }

        // Past the guard above we are provably on the main thread, so it is safe
        // to assert main-actor isolation for the UIKit work below rather than
        // hopping again. Behavior is unchanged — the dispatch structure below is
        // identical to before.
        MainActor.assumeIsolated {
            let delegate = UIApplication.shared.delegate
            guard var base = delegate?.window??.rootViewController else {
                TPPErrorLogger.logError(withCode: .missingExpectedObject,
                                        summary: "Unable to find rootViewController",
                                        metadata: [
                                            "DelegateIsNil": (delegate == nil),
                                            "WindowIsNil": (delegate?.window == nil)
                                        ])
                return
            }

            while true {
                guard let topBase = base.presentedViewController else {
                    break
                }
                base = topBase
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
                        safelyPresent(payload.viewController, animated: animated, completion: payload.completion)
                    }
                }
                return
            }

            base.present(payload.viewController, animated: animated, completion: payload.completion)
        }
    }
}
