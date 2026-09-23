//
//  The Palace Project
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

// `@MainActor`: this helper builds `UIAlertController` / `UIAlertAction`
// instances — main-actor UIKit types — and its actions fire the completion
// on the main actor via the alert-action handler (itself `@MainActor
// @Sendable` in the SDK). Isolating the whole helper to the main actor is the
// correct, isolation-only fix; the completion/handler closures are marked
// `@Sendable` so they can be captured by the `@MainActor @Sendable`
// UIAlertAction handler.
@MainActor
@objcMembers final class TPPReturnPromptHelper: NSObject {

    static func audiobookPrompt(completion: @escaping @MainActor @Sendable (_ returnWasChosen: Bool) -> Void) -> UIAlertController {
        let title = Strings.ReturnPromptHelper.audiobookPromptTitle
        let message = Strings.ReturnPromptHelper.audiobookPromptMessage
        let alert = UIAlertController.init(title: title, message: message, preferredStyle: .alert)
        let keepBook = keepAction {
            completion(false)
        }
        let returnBook = returnAction {
            completion(true)
        }
        alert.addAction(keepBook)
        alert.addAction(returnBook)
        return alert
    }

    private static func keepAction(handler: @escaping @MainActor @Sendable () -> Void) -> UIAlertAction {
        return UIAlertAction(
            title: Strings.ReturnPromptHelper.keepActionAlertTitle,
            style: .cancel,
            handler: { _ in handler() })
    }

    private static func returnAction(handler: @escaping @MainActor @Sendable () -> Void) -> UIAlertAction {
        return UIAlertAction(
            title: Strings.ReturnPromptHelper.returnActionTitle,
            style: .default,
            handler: { _ in handler() })
    }
}
