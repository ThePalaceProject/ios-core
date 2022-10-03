//
//  The Palace Project
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

@objcMembers final class TPPReturnPromptHelper: NSObject {

  class func audiobookPrompt(completion:@escaping (_ returnWasChosen:Bool)->()) -> UIAlertController
  {
    let title = DisplayStrings.ReturnPromptHelper.audiobookPromptTitle
    let message = DisplayStrings.ReturnPromptHelper.audiobookPromptMessage
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

  private class func keepAction(handler: @escaping () -> ()) -> UIAlertAction {
    return UIAlertAction(
      title: DisplayStrings.ReturnPromptHelper.keepActionAlertTitle,
      style: .cancel,
      handler: { _ in handler() })
  }

  private class func returnAction(handler: @escaping () -> ()) -> UIAlertAction {
    return UIAlertAction(
      title: DisplayStrings.ReturnPromptHelper.returnActionTitle,
      style: .default,
      handler: { _ in handler() })
  }
}
