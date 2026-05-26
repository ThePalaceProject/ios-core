//
//  BorrowErrorPresenter.swift
//  Palace
//
//  Owns the borrow-failure decision tree that lived inside
//  MyBooksDownloadCenter as `process(error:for:)` +
//  `handleInvalidCredentials(for:)` + `showAlert(for:with:alertTitle:)` +
//  `showGenericBorrowFailedAlert(for:)`.
//
//  Extracted so the borrow-error policy can be exercised in isolation
//  with mocks of the reauthenticator + delegate. The
//  `isRequestingCredentials` re-entrancy guard is shared with MBDC's
//  `requestCredentialsAndStartDownload` flow via a small
//  `CredentialRequestState` holder so concurrent sign-in modals are
//  prevented across both code paths.
//

import Foundation
import PalaceCatalog
import PalaceLogging

// MARK: - CredentialRequestState

/// Shared flag that gates concurrent sign-in modal presentations across
/// the borrow-error path (this presenter) and the start-download path
/// (MBDC's `requestCredentialsAndStartDownload`). Both paths read+write
/// the same instance so a modal already in flight from one path is
/// observed by the other.
///
/// The class itself is not `@MainActor` so MBDC's nonisolated init can
/// instantiate it. All read/write call sites hop to `@MainActor` first
/// (the consuming methods are themselves `@MainActor`), so the bool is
/// only ever touched from the main thread in practice — `@unchecked
/// Sendable` is the honest annotation for that contract.
final class CredentialRequestState: @unchecked Sendable {
    var isRequestingCredentials: Bool = false
}

// MARK: - BorrowErrorPresenterDelegate

protocol BorrowErrorPresenterDelegate: AnyObject {
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
    func startDownload(for book: TPPBook, withRequest request: URLRequest?)
}

// MARK: - BorrowErrorPresenter

/// Decides what to do with a borrow-time error: surface a "loan already
/// exists" message, kick a re-auth flow on invalid credentials, present
/// the generic borrow-failed alert with a retry action, or surface the
/// problem-document detail in a borrow-failed alert.
final class BorrowErrorPresenter {

    typealias DisplayStrings = Strings.MyDownloadCenter

    weak var delegate: BorrowErrorPresenterDelegate?

    private let progressReporter: DownloadProgressReporter
    private let userRetryTracker: UserRetryTracker
    private let reauthenticator: Reauthenticator
    private let userAccountProvider: () -> TPPUserAccount
    private let credentialRequestState: CredentialRequestState

    /// Per-presenter latch that pins us to ONE re-auth attempt per
    /// borrow flow. After the first attempt, subsequent invalid-
    /// credentials hits go straight to the alert.
    @MainActor private var hasAttemptedAuthentication = false

    init(
        progressReporter: DownloadProgressReporter,
        userRetryTracker: UserRetryTracker,
        reauthenticator: Reauthenticator,
        userAccountProvider: @escaping () -> TPPUserAccount,
        credentialRequestState: CredentialRequestState
    ) {
        self.progressReporter = progressReporter
        self.userRetryTracker = userRetryTracker
        self.reauthenticator = reauthenticator
        self.userAccountProvider = userAccountProvider
        self.credentialRequestState = credentialRequestState
    }

    // MARK: - process

    /// Routes a borrow-time error dictionary to the right alert / re-auth
    /// path. Called from MBDC's borrow flow on every problem-document
    /// failure.
    func process(error: [String: Any]?, for book: TPPBook) {
        guard let errorType = error?["type"] as? String else {
            showGenericBorrowFailedAlert(for: book)
            return
        }

        let alertTitle = DisplayStrings.borrowFailed

        switch errorType {
        case TPPProblemDocument.TypeLoanAlreadyExists:
            let alertMessage = DisplayStrings.loanAlreadyExistsAlertMessage
            runOnMainAsync { [weak self] in
                self?.progressReporter.publishAndAnnounceError(
                    DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage, kind: .borrow)
                )
            }

        case TPPProblemDocument.TypeInvalidCredentials:
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard !self.hasAttemptedAuthentication else {
                    self.showAlert(for: book, with: error, alertTitle: alertTitle)
                    return
                }

                guard !self.credentialRequestState.isRequestingCredentials else {
                    NSLog("Already requesting credentials, skipping re-authentication for: \(book.title)")
                    return
                }

                self.hasAttemptedAuthentication = true
                self.credentialRequestState.isRequestingCredentials = true

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.credentialRequestState.isRequestingCredentials = false
                }

                await self.handleInvalidCredentials(for: book)
            }
            return

        default:
            showAlert(for: book, with: error, alertTitle: alertTitle)
        }
    }

    // MARK: - Invalid-credentials → reauth + retry

    @MainActor
    private func handleInvalidCredentials(for book: TPPBook) {
        let userAccount = userAccountProvider()
        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) { [weak self] in
            guard let self = self else { return }

            Task { @MainActor [weak self] in
                self?.credentialRequestState.isRequestingCredentials = false

                if self?.userAccountProvider().hasCredentials() == true {
                    self?.delegate?.startDownload(for: book, withRequest: nil)
                } else {
                    NSLog("Authentication completed but no credentials present, user may have cancelled")
                }
            }
        }
    }

    // MARK: - Generic + problem-doc alerts

    private func showAlert(for book: TPPBook, with error: [String: Any]?, alertTitle: String) {
        var alertMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)

        if let error = error {
            let problemDoc = TPPProblemDocument.fromDictionary(error)
            if let detail = problemDoc.detail {
                alertMessage = "\(alertMessage)\n\n\(detail)"
            }
        }

        let retryAction = makeBorrowRetryAction(for: book)

        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage, kind: .borrow, retryAction: retryAction)
            )
        }
    }

    private func showGenericBorrowFailedAlert(for book: TPPBook) {
        let formattedMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)
        let retryAction = makeBorrowRetryAction(for: book)

        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: book.identifier, title: DisplayStrings.borrowFailed, message: formattedMessage, kind: .borrow, retryAction: retryAction)
            )
        }
    }

    /// Returns a retry closure that re-attempts the borrow for the given
    /// book when invoked, gated by the per-operation budget on
    /// `userRetryTracker`. Nil means "out of budget, hide the retry button".
    private func makeBorrowRetryAction(for book: TPPBook) -> (() -> Void)? {
        let operationId = "borrow-\(book.identifier)"
        guard userRetryTracker.canRetry(operationId: operationId) else { return nil }
        return { [weak self] in
            guard let self else { return }
            self.userRetryTracker.recordRetry(operationId: operationId)
            self.delegate?.startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
        }
    }
}
