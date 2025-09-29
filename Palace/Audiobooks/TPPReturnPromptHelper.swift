//
//  The Palace Project
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

@objcMembers final class TPPReturnPromptHelper: NSObject {
  class func audiobookPrompt(completion: @escaping (_ returnWasChosen: Bool) -> Void) -> UIAlertController {
    let title = Strings.ReturnPromptHelper.audiobookPromptTitle
    let message = Strings.ReturnPromptHelper.audiobookPromptMessage
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
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

  private class func keepAction(handler: @escaping () -> Void) -> UIAlertAction {
    UIAlertAction(
      title: Strings.ReturnPromptHelper.keepActionAlertTitle,
      style: .cancel,
      handler: { _ in handler() }
    )
  }

  private class func returnAction(handler: @escaping () -> Void) -> UIAlertAction {
    UIAlertAction(
      title: Strings.ReturnPromptHelper.returnActionTitle,
      style: .default,
      handler: { _ in handler() }
    )
  }
}
