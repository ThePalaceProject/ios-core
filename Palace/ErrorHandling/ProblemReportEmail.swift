import MessageUI
import UIKit

// MARK: - ProblemReportEmail

@objcMembers class ProblemReportEmail: NSObject {
  typealias DisplayStrings = Strings.ProblemReportEmail

  static let sharedInstance = ProblemReportEmail()

  fileprivate weak var lastPresentingViewController: UIViewController?

  func beginComposing(
    to emailAddress: String,
    presentingViewController: UIViewController,
    book: TPPBook?
  ) {
    beginComposing(to: emailAddress, presentingViewController: presentingViewController, body: generateBody(book: book))
  }

  func beginComposing(
    to emailAddress: String,
    presentingViewController: UIViewController,
    body: String
  ) {
    guard MFMailComposeViewController.canSendMail() else {
      let alertController = UIAlertController(
        title: DisplayStrings.noAccountSetupTitle,
        message: String(
          format: NSLocalizedString("Please contact %@ to report an issue.", comment: "Alert message"),
          emailAddress
        ),
        preferredStyle: .alert
      )
      alertController.addAction(
        UIAlertAction(
          title: Strings.Generic.ok,
          style: .default,
          handler: nil
        )
      )
      presentingViewController.present(alertController, animated: true)
      return
    }

    lastPresentingViewController = presentingViewController

    let mailComposeViewController = MFMailComposeViewController()
    mailComposeViewController.mailComposeDelegate = self
    mailComposeViewController.setSubject(TPPLocalizationNotNeeded("Problem Report"))
    mailComposeViewController.setToRecipients([emailAddress])
    mailComposeViewController.setMessageBody(body, isHTML: false)
    presentingViewController.present(mailComposeViewController, animated: true)
  }

  func generateBody(book: TPPBook?) -> String {
    let nativeHeight = UIScreen.main.nativeBounds.height
    let systemVersion = UIDevice.current.systemVersion
    let idiom = switch UIDevice.current.userInterfaceIdiom {
    case .carPlay:
      "carPlay"
    case .pad:
      "pad"
    case .phone:
      "phone"
    case .tv:
      "tv"
    case .mac:
      "mac"
    default:
      "unspecified"
      // #if swift(>=5.9)
//    case .vision:
//      return "vision"
      // #endif
//    @unknown default:         // for Xcode < 15
//      idiom = "unspecified"
    }

    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let bodyWithoutBook = "\n\n---\nIdiom: \(idiom)\nPlatform: iOS\nOS: \(systemVersion)\nHeight: \(nativeHeight)\nPalace Version: \(appVersion)\nLibrary: \(AccountsManager.shared.currentAccount?.name ?? "")"
    let body: String = if let book = book {
      bodyWithoutBook + "\nTitle: \(book.title)\nID: \(book.identifier)"
    } else {
      bodyWithoutBook
    }
    return body
  }
}

// MARK: MFMailComposeViewControllerDelegate

extension ProblemReportEmail: MFMailComposeViewControllerDelegate {
  func mailComposeController(
    _ controller: MFMailComposeViewController,
    didFinishWith result: MFMailComposeResult,
    error: Error?
  ) {
    controller.dismiss(animated: true, completion: nil)

    switch result {
    case .failed:
      if let error = error {
        let alertController = UIAlertController(
          title: Strings.Generic.error,
          message: error.localizedDescription,
          preferredStyle: .alert
        )
        alertController.addAction(
          UIAlertAction(
            title: Strings.Generic.ok,
            style: .default,
            handler: nil
          )
        )
        lastPresentingViewController?.present(alertController, animated: true, completion: nil)
      }
    case .sent:
      let alertController = UIAlertController(
        title: DisplayStrings.reportSentTitle,
        message: DisplayStrings.reportSentBody,
        preferredStyle: .alert
      )
      alertController.addAction(
        UIAlertAction(
          title: Strings.Generic.ok,
          style: .default,
          handler: nil
        )
      )
      lastPresentingViewController?.present(alertController, animated: true, completion: nil)
    case .cancelled: fallthrough
    case .saved:
      break
    }
  }
}
