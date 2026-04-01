import MessageUI
import UIKit

@objcMembers class ProblemReportEmail: NSObject {
    typealias DisplayStrings = Strings.ProblemReportEmail

    static let sharedInstance = ProblemReportEmail()

    fileprivate weak var lastPresentingViewController: UIViewController?

    func beginComposing(
        to emailAddress: String,
        presentingViewController: UIViewController,
        book: TPPBook?) {
        beginComposing(to: emailAddress, presentingViewController: presentingViewController, book: book, libraryUUID: nil)
    }

    /// Composes a problem report email using the patron ID for the specified library.
    /// - Parameters:
    ///   - emailAddress: The support email address.
    ///   - presentingViewController: The view controller to present the mail composer from.
    ///   - book: An optional book associated with the report.
    ///   - libraryUUID: The UUID of the library being viewed. When nil, falls back to the active library.
    func beginComposing(
        to emailAddress: String,
        presentingViewController: UIViewController,
        book: TPPBook?,
        libraryUUID: String?,
        accountsManager: AccountsManager = .shared) {
        let account = TPPUserAccount.sharedAccount(libraryUUID: libraryUUID ?? accountsManager.currentAccountId)
        let patronID = account.authorizationIdentifier
        beginComposing(to: emailAddress, presentingViewController: presentingViewController, body: generateBody(book: book, patronIdentifier: patronID))
    }

    func beginComposing(
        to emailAddress: String,
        presentingViewController: UIViewController,
        body: String) {
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

    func generateBody(book: TPPBook?, patronIdentifier: String? = nil, accountsManager: AccountsManager = .shared) -> String {
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
        default:
            idiom = "unspecified"
        // #if swift(>=5.9)
        //    case .vision:
        //      return "vision"
        // #endif
        //    @unknown default:         // for Xcode < 15
        //      idiom = "unspecified"
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        var body = "\n\n---\nIdiom: \(idiom)\nPlatform: iOS\nOS: \(systemVersion)\nHeight: \(nativeHeight)\nPalace Version: \(appVersion)\nLibrary: \(accountsManager.currentAccount?.name ?? "")"

        if let patronIdentifier = patronIdentifier {
            body += "\nPatron ID: \(patronIdentifier)"
        }

        if let book = book {
            body += "\nTitle: \(book.title)\nID: \(book.identifier)"
        }

        return body
    }
}

extension ProblemReportEmail: MFMailComposeViewControllerDelegate {
    func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?) {
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
        @unknown default:
            break
        }
    }
}
