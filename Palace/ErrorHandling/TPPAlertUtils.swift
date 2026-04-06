import Foundation
import UIKit

@objcMembers class TPPAlertUtils: NSObject {
    /**
     Generates an alert view controller. If the `message` is non-nil, it will be
     used instead of deriving the error message from the `error`.

     - Parameter title: The alert title; can be a localization key.
     - Parameter error: An error. If the error contains a localizedDescription, that will be used for the alert message.
     - Returns: The alert controller to be presented.
     */
    class func alert(title: String?,
                     message: String?,
                     error: NSError?) -> UIAlertController {
        if let message = message {
            return alert(title: title, message: message)
        } else {
            return alert(title: title, error: error)
        }
    }

    /**
     Generates an alert view from errors of domains: NSURLErrorDomain, NYPLADEPTErrorDomain

     - Parameter title: The alert title; can be a localization key.
     - Parameter error: An error. If the error contains a localizedDescription, that will be used for the alert message.
     - Returns: The alert controller to be presented.
     */
    class func alert(title: String?, error: NSError?) -> UIAlertController {
        // IMPORTANT: Log all errors that result in user-facing alerts
        // This ensures enhanced logging captures them
        if let error = error {
            TPPErrorLogger.logError(
                error,
                summary: "Error alert shown to user: \(title ?? "Unknown")",
                metadata: ["alert_title": title ?? "N/A"]
            )
        }

        // Track in the activity trail for error detail views
        Task {
            let msg = "Error alert: \(title ?? "Unknown") — \(error?.localizedDescription ?? "no error")"
            await ErrorActivityTracker.shared.log(msg, category: .general)
        }

        var message = ""
        let domain = error?.domain ?? ""
        let code = error?.code ?? 0

        // handle common iOS networking errors
        if domain == NSURLErrorDomain {
            if code == NSURLErrorNotConnectedToInternet {
                message = "NotConnected"
            } else if code == NSURLErrorCancelled {
                message = "Cancelled"
            } else if code == NSURLErrorTimedOut {
                message = "TimedOut"
            } else if code == NSURLErrorUnsupportedURL {
                message = "UnsupportedURL"
            } else {
                message = "UnknownRequestError"
            }
        }
        #if FEATURE_DRM_CONNECTOR
        if domain == NYPLADEPTErrorDomain {
            if code == NYPLADEPTError.authenticationFailed.rawValue {
                message = "SettingsAccountViewControllerInvalidCredentials"
            } else if code == NYPLADEPTError.tooManyActivations.rawValue {
                message = "SettingsAccountViewControllerMessageTooManyActivations"
            } else {
                message = "DRM error: \(error?.localizedDescriptionWithRecovery ?? "Please try again.")"
            }
        }
        #endif

        if message.isEmpty {
            // since it wasn't a networking or Adobe DRM error, show the error
            // description if present
            if let errorDescription = error?.localizedDescriptionWithRecovery, !errorDescription.isEmpty {
                message = errorDescription
            } else {
                message = "An error occurred. Please try again later or report an issue from the Settings tab."
                var metadata = [String: Any]()
                metadata["alertTitle"] = title ?? "N/A"
                if let error = error {
                    metadata["error"] = error
                    metadata["message"] = "Error object contained no usable error message for the user, so we defaulted to a generic one."
                }
                TPPErrorLogger.logError(withCode: .genericErrorMsgDisplayed,
                                        summary: "Displayed error alert with generic message",
                                        metadata: metadata)
            }
        }

        return alert(title: title, message: message)
    }

    /**
     Generates an alert view with localized strings and default style
     @param title the alert title; can be localization key
     @param message the alert message; can be localization key
     @return the alert
     */
    class func alert(title: String?, message: String?) -> UIAlertController {
        return alert(title: title, message: message, style: .default)
    }

    /**
     Generates an alert view with localized strings
     @param title the alert title; can be localization key
     @param message the alert message; can be localization key
     @param style the OK action style
     @return the alert
     */
    class func alert(title: String?, message: String?, style: UIAlertAction.Style) -> UIAlertController {
        let alertTitle = (title?.count ?? 0) > 0 ? NSLocalizedString(title!, comment: "") : "Alert"
        let alertMessage = (message?.count ?? 0) > 0 ? NSLocalizedString(message!, comment: "") : ""
        let alertController = UIAlertController.init(
            title: alertTitle,
            message: alertMessage,
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction.init(title: NSLocalizedString("OK", comment: ""), style: style, handler: nil))
        return alertController
    }

    /**
     Adds a problem document's contents to the alert
     @param controller the alert to modify
     @param document the problem document
     @param append appends the problem document title and details to the alert if true; sets the alert title and message to problem document contents otherwise
     @return
     */
    class func setProblemDocument(controller: UIAlertController?, document: TPPProblemDocument?, append: Bool) {
        guard let alert = controller else {
            return
        }
        guard let document = document else {
            return
        }

        var titleWasAdded = false
        var detailWasAdded = false
        if append == false {
            if let problemDocTitle = document.title, !problemDocTitle.isEmpty {
                alert.title = document.title
                titleWasAdded = true
            }
            if let problemDocDetail = document.detail, !problemDocDetail.isEmpty {
                alert.message = document.detail
                detailWasAdded = true
                if titleWasAdded {
                    // now we know we set both the alert's title and message, and since
                    // we are not appending (i.e. we are replacing what was on the
                    // existing alert), we are done.
                    return
                }
            }
        }

        // at this point either the alert's title or message could be empty.
        // Let's fill that up with what we have, either from the existing alert
        // or from the problem document.

        if alert.title?.isEmpty ?? true {
            alert.title = document.title
            titleWasAdded = true
        }

        let existingMsg: String = {
            if let alertMsg = alert.message, !alertMsg.isEmpty {
                return alertMsg + "\n"
            }
            return ""
        }()

        let docDetail = detailWasAdded ? "" : (document.detail ?? "")

        if !titleWasAdded, let docTitle = document.title, !docTitle.isEmpty, docTitle != alert.title {
            alert.message = "\(existingMsg)\(docTitle)\n\(docDetail)"
        } else {
            alert.message = "\(existingMsg)\(docDetail)"
        }
    }

    /**
     Presents an alert view from another given view, assuming the current
     window's root view controller is `NYPLRootTabBarController::shared`.

     - Parameters:
     - alertController: The alert to display.
     - viewController: The view from which the alert is displayed.
     - animated: Whether to animate the presentation of the alert or not.
     - completion: Callback passed on to UIViewcontroller::present().
     */
    /// Maximum number of retry attempts for alert presentation when a view
    /// controller is mid-transition or otherwise temporarily unable to present.
    private static let maxAlertRetries = 3

    class func presentFromViewControllerOrNil(alertController: UIAlertController?,
                                              viewController: UIViewController?,
                                              animated: Bool,
                                              completion: (() -> Void)?) {
        // PP-3673: Announce the alert to VoiceOver without moving focus.
        // This ensures assistive-technology users hear error/status messages
        // even if UIKit focus changes are delayed or suppressed.
        if let alert = alertController, UIAccessibility.isVoiceOverRunning {
            let announcement = [alert.title, alert.message]
                .compactMap { $0 }
                .joined(separator: ". ")
            if !announcement.isEmpty {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }

        presentFromViewControllerOrNil(
            alertController: alertController,
            viewController: viewController,
            animated: animated,
            completion: completion,
            retryCount: 0
        )
    }

    private class func presentFromViewControllerOrNil(alertController: UIAlertController?,
                                                      viewController: UIViewController?,
                                                      animated: Bool,
                                                      completion: (() -> Void)?,
                                                      retryCount: Int) {
        guard let alertController = alertController else {
            return
        }

        // If a presenter is provided, present from it on main thread
        if let vc = viewController {
            DispatchQueue.main.async {
                guard vc.presentedViewController == nil else {
                    Log.warn(#file, "Cannot present alert: view controller already presenting")
                    completion?()
                    return
                }
                // Guard: VC may have a live transition coordinator (e.g. a push/pop
                // animation still in flight) even when isBeingPresented is false.
                // Presenting into an active transition causes UIKit to throw
                // NSInternalInconsistencyException during the CA commit phase.
                guard vc.transitionCoordinator == nil else {
                    if retryCount < maxAlertRetries {
                        Log.debug(#file, "Presenter has active transition coordinator, retrying (\(retryCount + 1)/\(maxAlertRetries))...")
                        retryPresentation(alertController: alertController, viewController: viewController,
                                          animated: animated, completion: completion, retryCount: retryCount)
                    } else {
                        Log.warn(#file, "Cannot present alert after \(maxAlertRetries) retries: presenter still has active transition")
                        completion?()
                    }
                    return
                }
                guard !vc.isBeingPresented && !vc.isBeingDismissed else {
                    if retryCount < maxAlertRetries {
                        Log.debug(#file, "Presenter is in transition, retrying (\(retryCount + 1)/\(maxAlertRetries))...")
                        retryPresentation(alertController: alertController, viewController: viewController,
                                          animated: animated, completion: completion, retryCount: retryCount)
                    } else {
                        Log.warn(#file, "Cannot present alert after \(maxAlertRetries) retries: presenter still in transition")
                        completion?()
                    }
                    return
                }
                safePresent(alertController, on: vc, animated: animated, completion: completion)
            }
            return
        }

        // SwiftUI-first: present from the app's top-most UIKit controller
        DispatchQueue.main.async {
            guard let root = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() else {
                Log.error(#file, "Cannot present alert: no root view controller available")
                if let msg = alertController.message {
                    Log.error(#file, "Failed to present alert with message: \(msg)")
                }
                completion?()
                return
            }

            let top = topMostViewController(from: root)

            // Safety: never present from a UIAlertController
            guard !(top is UIAlertController) else {
                // Retry: the alert may dismiss shortly, allowing us to present
                if retryCount < maxAlertRetries {
                    Log.debug(#file, "Top controller is a UIAlertController, retrying (\(retryCount + 1)/\(maxAlertRetries))...")
                    retryPresentation(alertController: alertController, viewController: viewController,
                                      animated: animated, completion: completion, retryCount: retryCount)
                } else {
                    Log.warn(#file, "Cannot present alert after \(maxAlertRetries) retries: top controller is still a UIAlertController")
                    if let msg = alertController.message {
                        Log.warn(#file, "Dropped alert with message: \(msg)")
                    }
                    completion?()
                }
                return
            }

            // Additional safety check: ensure view controller can present
            guard top.view.window != nil else {
                Log.error(#file, "Cannot present alert: view controller not in window hierarchy")
                if let msg = alertController.message {
                    Log.error(#file, "Failed to present alert with message: \(msg)")
                }
                completion?()
                return
            }

            guard top.isViewLoaded else {
                Log.warn(#file, "Cannot present alert: view not loaded")
                completion?()
                return
            }

            // Guard: a live transition coordinator means a navigation push/pop or modal
            // animation is still in-flight at the CALayer level, even if isBeingPresented
            // is already false. Presenting into this window triggers UIKit's
            // NSInternalInconsistencyException during _UIAfterCACommitBlock execution.
            guard top.transitionCoordinator == nil else {
                if retryCount < maxAlertRetries {
                    Log.debug(#file, "Top controller has active transition coordinator, retrying (\(retryCount + 1)/\(maxAlertRetries))...")
                    retryPresentation(alertController: alertController, viewController: viewController,
                                      animated: animated, completion: completion, retryCount: retryCount)
                } else {
                    Log.warn(#file, "Cannot present alert after \(maxAlertRetries) retries: transition coordinator still active")
                    if let msg = alertController.message {
                        Log.warn(#file, "Dropped alert with message: \(msg)")
                    }
                    completion?()
                }
                return
            }

            // Retry during view controller transitions instead of dropping the alert.
            // Transitions are short-lived so a brief delay is sufficient.
            guard !top.isBeingPresented && !top.isBeingDismissed else {
                if retryCount < maxAlertRetries {
                    Log.debug(#file, "View controller is in transition, retrying (\(retryCount + 1)/\(maxAlertRetries))...")
                    retryPresentation(alertController: alertController, viewController: viewController,
                                      animated: animated, completion: completion, retryCount: retryCount)
                } else {
                    Log.warn(#file, "Cannot present alert after \(maxAlertRetries) retries: view controller still in transition")
                    if let msg = alertController.message {
                        Log.warn(#file, "Dropped alert with message: \(msg)")
                    }
                    completion?()
                }
                return
            }

            // If already presenting, try to present on top of the presented controller
            if let presented = top.presentedViewController {
                // Check if the presented controller is another alert - retry instead of dropping
                if presented is UIAlertController {
                    if retryCount < maxAlertRetries {
                        Log.debug(#file, "Another alert is visible, retrying (\(retryCount + 1)/\(maxAlertRetries))...")
                        retryPresentation(alertController: alertController, viewController: viewController,
                                          animated: animated, completion: completion, retryCount: retryCount)
                    } else {
                        Log.warn(#file, "Cannot present alert after \(maxAlertRetries) retries: another alert is still visible")
                        if let msg = alertController.message {
                            Log.warn(#file, "Dropped alert with message: \(msg)")
                        }
                        completion?()
                    }
                    return
                }

                // Ensure presented view controller is in valid state
                guard presented.isViewLoaded, presented.view.window != nil else {
                    if retryCount < maxAlertRetries {
                        Log.debug(#file, "Presented view controller not ready, retrying (\(retryCount + 1)/\(maxAlertRetries))...")
                        retryPresentation(alertController: alertController, viewController: viewController,
                                          animated: animated, completion: completion, retryCount: retryCount)
                    } else {
                        Log.warn(#file, "Cannot present alert after \(maxAlertRetries) retries: presented view controller not ready")
                        if let msg = alertController.message {
                            Log.error(#file, "Dropped alert with message: \(msg)")
                        }
                        completion?()
                    }
                    return
                }

                safePresent(alertController, on: presented, animated: animated, completion: completion)
            } else {
                safePresent(alertController, on: top, animated: animated, completion: completion)
            }
        }
    }

    /// Presents an alert controller wrapped in ObjC exception handling.
    /// UIKit can throw NSInternalInconsistencyException during animated transitions
    /// when the view hierarchy is in an unexpected state (e.g. a VC that doesn't
    /// contain an alert controller is asked for its contained alert controller).
    private class func safePresent(_ alertController: UIAlertController,
                                   on presenter: UIViewController,
                                   animated: Bool,
                                   completion: (() -> Void)?) {
        let exception = TPPObjCExceptionCatcher.catchException {
            presenter.present(alertController, animated: animated, completion: completion)
        }
        if let exception = exception {
            Log.error(#file, "ObjC exception presenting alert: \(exception.name.rawValue) — \(exception.reason ?? "unknown")")
            completion?()
            return
        }
        if let msg = alertController.message { Log.info(#file, msg) }
    }

    /// Retries alert presentation after a short delay to allow transitions to complete.
    private class func retryPresentation(alertController: UIAlertController,
                                         viewController: UIViewController?,
                                         animated: Bool,
                                         completion: (() -> Void)?,
                                         retryCount: Int) {
        // Exponential backoff: 0.4s, 0.8s, 1.6s
        let delay = 0.4 * pow(2.0, Double(retryCount))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            presentFromViewControllerOrNil(
                alertController: alertController,
                viewController: viewController,
                animated: animated,
                completion: completion,
                retryCount: retryCount + 1
            )
        }
    }

    // MARK: - View Error Details

    /// Creates an alert with a "View Error Details" button that presents
    /// a detailed error report including activity trail, problem document,
    /// and device context.
    ///
    /// When `retryAction` is provided, the alert shows "Retry" + "Cancel"
    /// instead of a single "OK" button (PP-3707).
    ///
    /// This is the primary integration point for PP-3439.
    class func alertWithDetails(
        title: String?,
        message: String?,
        error: NSError? = nil,
        problemDocument: TPPProblemDocument? = nil,
        bookIdentifier: String? = nil,
        bookTitle: String? = nil,
        retryAction: (() -> Void)? = nil
    ) -> UIAlertController {
        // Build the base alert using existing logic
        let alertController: UIAlertController
        if let error = error {
            alertController = alert(title: title, message: message, error: error)
        } else {
            alertController = alert(title: title, message: message)
        }

        // Remove the default OK action so we can reorder buttons
        alertController.actions.forEach { _ in } // actions are read-only, so we build a new one
        let freshAlert = UIAlertController(
            title: alertController.title,
            message: alertController.message,
            preferredStyle: .alert
        )

        // Capture values for the closure
        let alertTitle = freshAlert.title ?? title ?? "Error"
        let alertMessage = freshAlert.message ?? message ?? ""

        // "View Error Details" button
        freshAlert.addAction(UIAlertAction(title: "View Error Details", style: .default) { _ in
            Task {
                let detail = await ErrorDetail.capture(
                    title: alertTitle,
                    message: alertMessage,
                    error: error,
                    problemDocument: problemDocument,
                    bookIdentifier: bookIdentifier,
                    bookTitle: bookTitle
                )

                await MainActor.run {
                    let detailVC = ErrorDetailViewController(errorDetail: detail)
                    let nav = UINavigationController(rootViewController: detailVC)
                    nav.modalPresentationStyle = .fullScreen

                    // Present from the top-most view controller
                    if let root = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
                        let top = topMostViewController(from: root)

                        // Safety: don't present from a UIAlertController or a VC mid-transition
                        guard !(top is UIAlertController) else {
                            Log.warn(#file, "Cannot present error details: top controller is an alert")
                            return
                        }
                        guard !top.isBeingPresented && !top.isBeingDismissed else {
                            Log.warn(#file, "Cannot present error details: view controller is in transition")
                            return
                        }

                        // If already presenting something, present from the presented VC
                        if let presented = top.presentedViewController {
                            guard !(presented is UIAlertController) else {
                                Log.warn(#file, "Cannot present error details: an alert is already visible")
                                return
                            }
                            presented.present(nav, animated: true)
                        } else {
                            top.present(nav, animated: true)
                        }
                    }
                }
            }
        })

        // PP-3707: Add Retry + Cancel for retryable errors, or OK for non-retryable
        if let retryAction = retryAction {
            let retry = UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { _ in
                retryAction()
            }
            retry.accessibilityIdentifier = AccessibilityID.ErrorAlert.retryButton
            let cancel = UIAlertAction(title: Strings.Generic.cancel, style: .cancel)
            cancel.accessibilityIdentifier = AccessibilityID.ErrorAlert.cancelButton
            freshAlert.addAction(retry)
            freshAlert.addAction(cancel)
        } else {
            let ok = UIAlertAction(title: Strings.Generic.ok, style: .default)
            ok.accessibilityIdentifier = AccessibilityID.ErrorAlert.okButton
            freshAlert.addAction(ok)
        }

        return freshAlert
    }

    // MARK: - Helpers
    private class func topMostViewController(from base: UIViewController) -> UIViewController {
        if let nav = base as? UINavigationController, let visible = nav.visibleViewController {
            return topMostViewController(from: visible)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topMostViewController(from: selected)
        }
        if let presented = base.presentedViewController {
            // Don't traverse into UIAlertControllers. Alert controllers cannot present
            // other view controllers, and attempting to do so causes
            // NSInternalInconsistencyException ("A view controller not containing an
            // alert controller was asked for its contained alert controller").
            // By returning `base` here, the caller can check base.presentedViewController
            // and see the alert, allowing proper guard logic to skip stacking alerts.
            if presented is UIAlertController {
                return base
            }
            return topMostViewController(from: presented)
        }
        return base
    }
}
