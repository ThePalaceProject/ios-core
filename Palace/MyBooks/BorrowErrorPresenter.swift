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

// MARK: - Carrier boxes

/// Carrier box that lets the non-Sendable `TPPBook` ride inside a
/// `@Sendable` closure (the `@MainActor` re-auth Task and the `@Sendable`
/// retry closures). The book is read-only after construction and the
/// closures only ever touch it on the main actor, so `@unchecked Sendable`
/// is sound. Mirrors the carrier-box precedent (`CarPlayImageCompletionBox`,
/// `ReadiumBookmarkBox`).
private final class BorrowBookBox: @unchecked Sendable {
    let book: TPPBook
    init(_ book: TPPBook) { self.book = book }
}

/// Carrier box for the non-Sendable `[String: Any]?` problem-error
/// dictionary so it can cross into the `@MainActor @Sendable` re-auth Task.
/// Read-only after construction; only decoded (`TPPProblemDocument.from
/// Dictionary`) on the main actor. `@unchecked Sendable` is sound for the
/// same read-only-single-consumer reason as `BorrowBookBox`.
private final class BorrowErrorDictBox: @unchecked Sendable {
    let error: [String: Any]?
    init(_ error: [String: Any]?) { self.error = error }
}

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
///
/// `@unchecked Sendable` invariant (Swift 6 `complete`-mode slice): every
/// injected collaborator is an immutable `let` (`progressReporter`,
/// `userRetryTracker`, `reauthenticator`, `userAccountProvider`,
/// `credentialRequestState` — the last is itself `@unchecked Sendable`). The
/// only mutable instance storage is the `@MainActor`-isolated
/// `hasAttemptedAuthentication` latch (read/written solely on the main actor)
/// and `weak var delegate` (assigned once on the main thread during
/// `MyBooksDownloadCenter` init, read only from `@MainActor`-hopped
/// contexts). `@unchecked` is required only so `self` can be captured by the
/// `@Sendable` alert/reauth closures — not because any state is racy. Mirrors
/// sibling presenters in this module (`CredentialPromptCoordinator`,
/// `BookSignInRedirectHandler`, `DownloadAuthRetryHandler`).
final class BorrowErrorPresenter: @unchecked Sendable {

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
        // `book` (non-Sendable `TPPBook`) and `error` (`Any`-valued dict) ride
        // whole into the `@MainActor @Sendable` Task via read-only carrier
        // boxes; the boxed values are only touched on the main actor inside
        // `processAsync`.
        let bookBox = BorrowBookBox(book)
        let errorBox = BorrowErrorDictBox(error)
        Task { @MainActor [weak self] in
            await self?.processAsync(error: errorBox.error, for: bookBox.book)
        }
    }

    /// Behavior-identical `async` sibling of `process`. Fire-and-forget
    /// `process` is `Task { await processAsync(...) }`; callers already inside
    /// an `async @MainActor` context (and tests) can `await` it directly to
    /// JOIN every branch's side effects — the alert publish, the re-auth
    /// dispatch, and the post-reauth `startDownload` retry — instead of
    /// polling a wall-clock deadline for a fire-and-forget hop to settle.
    ///
    /// Structurally identical to the previous `process` body: the branch-1/2/4
    /// publishes happen on the main actor (previously via `runOnMainAsync`,
    /// now directly — we are already on `@MainActor`, same thread, same
    /// order), and the invalid-credentials branch keeps the same guard order,
    /// the same one-shot latch, the same shared-flag set, and the same
    /// fire-and-forget 2s `isRequestingCredentials` reset Task.
    @MainActor
    func processAsync(error: [String: Any]?, for book: TPPBook) async {
        guard let errorType = error?["type"] as? String else {
            showGenericBorrowFailedAlert(for: book)
            return
        }

        let alertTitle = DisplayStrings.borrowFailed

        switch errorType {
        case TPPProblemDocument.TypeLoanAlreadyExists:
            let alertMessage = DisplayStrings.loanAlreadyExistsAlertMessage
            progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage, kind: .borrow)
            )

        case TPPProblemDocument.TypeInvalidCredentials:
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

        default:
            showAlert(for: book, with: error, alertTitle: alertTitle)
        }
    }

    // MARK: - Invalid-credentials → reauth + retry

    @MainActor
    private func handleInvalidCredentials(for book: TPPBook) async {
        let userAccount = userAccountProvider()

        // Bridge the completion-handler reauthenticator API to `async` so the
        // caller (`processAsync`) can JOIN the retry. The post-reauth body runs
        // on the main actor exactly as before — previously it hopped through
        // `Task { @MainActor }` from the (possibly-nonisolated) completion; now
        // we resume back onto the main actor via the continuation and run it
        // inline. Same thread, same order, same observable effects
        // (`isRequestingCredentials` reset → conditional `startDownload`).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) {
                continuation.resume()
            }
        }

        credentialRequestState.isRequestingCredentials = false

        if userAccountProvider().hasCredentials() {
            delegate?.startDownload(for: book, withRequest: nil)
        } else {
            NSLog("Authentication completed but no credentials present, user may have cancelled")
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

        // Snapshot the Sendable identifier so the non-Sendable `book` does not
        // cross into the `@MainActor @Sendable` closure. `retryAction` is now
        // `@Sendable` (see `makeBorrowRetryAction`), so it too is safe to capture.
        let bookId = book.identifier

        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: bookId, title: alertTitle, message: alertMessage, kind: .borrow, retryAction: retryAction)
            )
        }
    }

    private func showGenericBorrowFailedAlert(for book: TPPBook) {
        let formattedMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)
        let retryAction = makeBorrowRetryAction(for: book)

        // Snapshot the Sendable identifier so the non-Sendable `book` does not
        // cross into the `@MainActor @Sendable` closure. `retryAction` is now
        // `@Sendable` (see `makeBorrowRetryAction`), so it too is safe to capture.
        let bookId = book.identifier

        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: bookId, title: DisplayStrings.borrowFailed, message: formattedMessage, kind: .borrow, retryAction: retryAction)
            )
        }
    }

    /// Returns a retry closure that re-attempts the borrow for the given
    /// book when invoked, gated by the per-operation budget on
    /// `userRetryTracker`. Nil means "out of budget, hide the retry button".
    ///
    /// Returns a `@Sendable` closure so it can be captured by the
    /// `@MainActor @Sendable` alert-publication closures. The closure needs
    /// the whole non-Sendable `book` to re-drive `startBorrow`, so it is
    /// threaded through a `BorrowBookBox` carrier: the book is read-only
    /// inside the closure and the closure is only ever invoked on the main
    /// actor (from the alert's Retry button), so `@unchecked Sendable` on the
    /// box is sound.
    private func makeBorrowRetryAction(for book: TPPBook) -> (@Sendable () -> Void)? {
        let operationId = "borrow-\(book.identifier)"
        guard userRetryTracker.canRetry(operationId: operationId) else { return nil }
        let bookBox = BorrowBookBox(book)
        return { [weak self] in
            guard let self else { return }
            self.userRetryTracker.recordRetry(operationId: operationId)
            self.delegate?.startBorrow(for: bookBox.book, attemptDownload: true, borrowCompletion: nil)
        }
    }
}
