//
//  The Palace Project
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

@objcMembers final class TPPReturnPromptHelper: NSObject {

    static func audiobookPrompt(completion: @escaping (_ returnWasChosen: Bool) -> Void) -> UIAlertController {
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

    private static func keepAction(handler: @escaping () -> Void) -> UIAlertAction {
        return UIAlertAction(
            title: Strings.ReturnPromptHelper.keepActionAlertTitle,
            style: .cancel,
            handler: { _ in handler() })
    }

    private static func returnAction(handler: @escaping () -> Void) -> UIAlertAction {
        return UIAlertAction(
            title: Strings.ReturnPromptHelper.returnActionTitle,
            style: .default,
            handler: { _ in handler() })
    }
}
