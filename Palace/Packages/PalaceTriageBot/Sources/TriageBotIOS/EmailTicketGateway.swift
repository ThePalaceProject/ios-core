#if canImport(MessageUI)
import Foundation
import UIKit
import MessageUI
import TriageBotCore

/// Submits a TicketDraft by opening the iOS native mail composer pre-filled
/// with the support address, a readable email body, and two attachments:
///
///   - `palace-diagnostics.json` — full machine-readable TicketDraft payload
///   - `palace-logs.txt` — redacted log tail as plain text (separate so
///     support can scan it without un-zipping JSON)
///
/// Falls back to ClipboardTicketGateway when the device has no mail account
/// configured (`MFMailComposeViewController.canSendMail()` is false). This
/// keeps the gateway usable on simulators without a Mail account.
///
/// **Privacy posture.** This gateway hands a pre-filled draft to the OS mail
/// composer. The user reviews the body + attachments + recipient and chooses
/// to Send or Cancel from their own Mail account — the app never sends email
/// programmatically. That's Apple's contract for MFMailComposeViewController
/// and the right consent model for support reports.
@MainActor
public final class EmailTicketGateway: NSObject, TicketGateway, MFMailComposeViewControllerDelegate {

    private let supportEmail: String
    private let fallback: TicketGateway?
    private let presenter: @MainActor () -> UIViewController?
    private var continuation: CheckedContinuation<TicketReceipt, Error>?

    /// - Parameters:
    ///   - supportEmail: recipient address. Defaults to the Palace support
    ///     mailbox; override for staged rollouts (e.g. a demo address).
    ///   - fallback: gateway to use when the device can't send mail.
    ///     Defaults to ClipboardTicketGateway so the demo flow keeps working
    ///     on a simulator without a configured Mail account.
    ///   - presenter: closure that returns the view controller to present
    ///     the mail composer on. Defaults to the topmost VC in the active
    ///     UIWindowScene.
    public init(
        supportEmail: String = "support@thepalaceproject.org",
        fallback: TicketGateway? = ClipboardTicketGateway(),
        presenter: @escaping @MainActor () -> UIViewController? = triageBotDefaultPresenter
    ) {
        self.supportEmail = supportEmail
        self.fallback = fallback
        self.presenter = presenter
        super.init()
    }

    public func submit(_ draft: TicketDraft) async throws -> TicketReceipt {
        guard MFMailComposeViewController.canSendMail() else {
            if let fallback = fallback {
                return try await fallback.submit(draft)
            }
            throw EmailGatewayError.mailUnavailable
        }
        guard let presenter = presenter() else {
            if let fallback = fallback {
                return try await fallback.submit(draft)
            }
            throw EmailGatewayError.noPresenter
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let composer = MFMailComposeViewController()
            composer.mailComposeDelegate = self
            composer.setToRecipients([supportEmail])
            composer.setSubject(TicketEmailComposition.subject(for: draft))
            composer.setMessageBody(TicketEmailComposition.body(for: draft), isHTML: false)

            for attachment in TicketEmailComposition.attachments(for: draft) {
                composer.addAttachmentData(
                    attachment.data,
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName
                )
            }

            presenter.present(composer, animated: true)
        }
    }

    // MARK: - MFMailComposeViewControllerDelegate

    public func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?
    ) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            let continuation = self.continuation
            self.continuation = nil
            guard let continuation else { return }

            switch result {
            case .sent:
                continuation.resume(returning: TicketReceipt(
                    ticketId: "EMAIL-\(Int(Date().timeIntervalSince1970))",
                    submittedAt: Date()
                ))
            case .saved:
                // User saved draft instead of sending — treat as cancelled
                // from the bot's perspective (we don't know if it'll ship).
                continuation.resume(throwing: EmailGatewayError.userCancelled)
            case .cancelled:
                continuation.resume(throwing: EmailGatewayError.userCancelled)
            case .failed:
                continuation.resume(throwing: error ?? EmailGatewayError.composerFailed)
            @unknown default:
                continuation.resume(throwing: EmailGatewayError.composerFailed)
            }
        }
    }

    // MARK: - Pure helpers (testable without UIKit / MessageUI)

    // Pure composition (subject / body / attachments) lives in TriageBotCore
    // (TicketEmailComposition) so it's testable without UIKit / MessageUI
    // and reusable by any future non-email gateway.

}

/// Default presenter — finds the top view controller of the active window
/// scene. Free function (not a method) so it can be used as the default
/// value of an `@MainActor` closure parameter without `Self`-type or
/// isolation problems.
@MainActor
public func triageBotDefaultPresenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
    guard let window = scenes.first?.windows.first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first else {
        return nil
    }
    var top = window.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

public enum EmailGatewayError: Error, LocalizedError {
    case mailUnavailable
    case noPresenter
    case userCancelled
    case composerFailed

    public var errorDescription: String? {
        switch self {
        case .mailUnavailable:
            return "Your device doesn't have a Mail account configured. The ticket was copied to your clipboard instead."
        case .noPresenter:
            return "Couldn't open the mail composer. The ticket was copied to your clipboard instead."
        case .userCancelled:
            return "Cancelled — nothing was sent."
        case .composerFailed:
            return "The mail composer ran into a problem. Try again, or copy the details and email support."
        }
    }
}
#endif
