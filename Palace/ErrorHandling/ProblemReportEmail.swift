import MessageUI
import UIKit

@objcMembers class ProblemReportEmail: NSObject {
  typealias DisplayStrings = Strings.ProblemReportEmail

  static let sharedInstance = ProblemReportEmail()
  
  fileprivate weak var lastPresentingViewController: UIViewController?
  
  func beginComposing(
    to emailAddress: String,
    presentingViewController: UIViewController,
    book: TPPBook?)
  {
    beginComposing(to: emailAddress, presentingViewController: presentingViewController, body: generateBody(book: book))
  }
  
  func beginComposing(
    to emailAddress: String,
    presentingViewController: UIViewController,
    body: String)
  {
    guard MFMailComposeViewController.canSendMail() else {
      let alertController = UIAlertController(
        title: DisplayStrings.noAccountSetupTitle,
        message: String(format: NSLocalizedString("Please contact %@ to report an issue.", comment: "Alert message"),
                        emailAddress),
        preferredStyle: .alert)
      alertController.addAction(
        UIAlertAction(title: Strings.Generic.ok,
                      style: .default,
                      handler: nil))
      presentingViewController.present(alertController, animated: true)
      return
    }
    
    self.lastPresentingViewController = presentingViewController
  
    let mailComposeViewController = MFMailComposeViewController.init()
    mailComposeViewController.mailComposeDelegate = self
    mailComposeViewController.setSubject(TPPLocalizationNotNeeded("Problem Report"))
    mailComposeViewController.setToRecipients([emailAddress])
    mailComposeViewController.setMessageBody(body, isHTML: false)
    presentingViewController.present(mailComposeViewController, animated: true)
  }
  
  func generateBody(book: TPPBook?) -> String {
    let nativeHeight = UIScreen.main.nativeBounds.height
    let systemVersion = UIDevice.current.systemVersion
    let idiom: String
    switch UIDevice.current.userInterfaceIdiom {
    case .carPlay:
      idiom = "carPlay"
    case .pad:
      idiom = "pad"
    case .phone:
      idiom = "phone"
    case .tv:
      idiom = "tv"
    case .mac:
      idiom = "mac"
    case .unspecified:
      idiom = "unspecified"
    }
    let bodyWithoutBook = "\n\n---\nIdiom: \(idiom)\nHeight: \(nativeHeight)\nOS: \(systemVersion)"
    let body: String
    if let book = book {
      body = bodyWithoutBook + "\nTitle: \(book.title)\nID: \(book.identifier)"
    } else {
      body = bodyWithoutBook
    }
    return body
  }
}

extension ProblemReportEmail: MFMailComposeViewControllerDelegate {
  func mailComposeController(
    _ controller: MFMailComposeViewController,
    didFinishWith result: MFMailComposeResult,
    error: Error?)
  {
    controller.dismiss(animated: true, completion: nil)
    
    switch result {
    case .failed:
      if let error = error {
        let alertController = UIAlertController(
          title: Strings.Generic.error,
          message: error.localizedDescription,
          preferredStyle: .alert)
        alertController.addAction(
          UIAlertAction(
            title: Strings.Generic.ok,
            style: .default,
            handler: nil))
        self.lastPresentingViewController?.present(alertController, animated: true, completion: nil)
      }
    case .sent:
      let alertController = UIAlertController(
        title: DisplayStrings.reportSentTitle,
        message: DisplayStrings.reportSentBody,
        preferredStyle: .alert)
      alertController.addAction(
        UIAlertAction(
          title: Strings.Generic.ok,
          style: .default,
          handler: nil))
      self.lastPresentingViewController?.present(alertController, animated: true, completion: nil)
    case .cancelled: fallthrough
    case .saved:
      break
    }
  }
}
