//
//  CredentialPromptCoordinator.swift
//  Palace
//
//  The start-download path for an account that needs auth but has no stored
//  credentials: present a sign-in modal (deduplicated via the shared
//  CredentialRequestState) and retry the download on success. An expired
//  Adobe certificate shows the dedicated alert instead of the modal.
//

import Foundation
import PalaceLogging
import PalaceBookModel

// MARK: - CredentialPromptCoordinatorDelegate

/// Surface MBDC needs to expose so the coordinator can retry the
/// download after sign-in completes.
protocol CredentialPromptCoordinatorDelegate: AnyObject {
    func startDownload(for book: TPPBook, withRequest request: URLRequest?)
}

// MARK: - CredentialPromptCoordinator

/// Coordinates the per-borrow credential-prompt flow.
///
/// `@unchecked Sendable` because `requestCredentialsAndStartDownload` captures
/// `[weak self]` into a `@Sendable` main-actor Task. Every stored member is a
/// `let` or main-actor-confined: `delegate` is set once during
/// `MyBooksDownloadCenter` construction and re-resolved through `self` on the
/// main actor; the closures and `credentialRequestState` are only used inside
/// the `@MainActor` Task body (the latter's confinement is by convention, not
/// compiler-enforced). `final`, so a subclass cannot break the invariant.
final class CredentialPromptCoordinator: @unchecked Sendable {

    weak var delegate: CredentialPromptCoordinatorDelegate?

    private let stateManager: DownloadStateManager
    private let userAccountProvider: () -> TPPUserAccount
    private let credentialRequestState: CredentialRequestState

    /// Closure that presents the sign-in modal and invokes the
    /// completion when the user finishes (or cancels). Production
    /// passes `SignInModalPresenter.presentSignInModalForCurrentAccount`.
    /// Tests stub this to drive the success/cancel branches without
    /// presenting a real modal.
    private let presentSignInModal: @MainActor (@escaping () -> Void) -> Void

    /// Closure returning whether Adobe DRM has expired. Production
    /// uses `AdobeCertificate.defaultCertificate?.hasExpired ?? false`
    /// when FEATURE_DRM_CONNECTOR is on; otherwise returns false.
    /// Tests inject any bool.
    private let isAdobeDRMExpired: () -> Bool

    /// Closure that presents the expired-Adobe-DRM alert. Production
    /// uses TPPAlertUtils.expiredAdobeDRMAlert + safelyPresent. Tests
    /// stub to assert the path was hit without UIKit.
    private let presentAdobeExpiredAlert: @MainActor () -> Void

    init(
        stateManager: DownloadStateManager,
        userAccountProvider: @escaping () -> TPPUserAccount,
        credentialRequestState: CredentialRequestState,
        presentSignInModal: @escaping @MainActor (@escaping () -> Void) -> Void,
        isAdobeDRMExpired: @escaping () -> Bool,
        presentAdobeExpiredAlert: @escaping @MainActor () -> Void
    ) {
        self.stateManager = stateManager
        self.userAccountProvider = userAccountProvider
        self.credentialRequestState = credentialRequestState
        self.presentSignInModal = presentSignInModal
        self.isAdobeDRMExpired = isAdobeDRMExpired
        self.presentAdobeExpiredAlert = presentAdobeExpiredAlert
    }

    // MARK: - Entry point

    /// Asks for sign-in credentials and retries the download for `book`
    /// once they're available. No-ops when another sign-in modal is
    /// already in flight (the shared CredentialRequestState gates this
    /// across the borrow-error path + the start-download path + the
    /// SAML redirect path).
    func requestCredentialsAndStartDownload(for book: TPPBook) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            guard !self.credentialRequestState.isRequestingCredentials else {
                NSLog("Already requesting credentials for authentication, skipping duplicate request for: \(book.title)")
                return
            }

            self.credentialRequestState.isRequestingCredentials = true

            // 2-second cooldown clears the gate even if the modal
            // never completes (e.g. user backgrounds the app).
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.credentialRequestState.isRequestingCredentials = false
            }

            if self.isAdobeDRMExpired() {
                self.credentialRequestState.isRequestingCredentials = false
                self.presentAdobeExpiredAlert()
                return
            }

            self.presentSignInModal { [weak self] in
                guard let self = self else { return }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.credentialRequestState.isRequestingCredentials = false

                    if self.userAccountProvider().hasCredentials() {
                        self.delegate?.startDownload(for: book, withRequest: nil)
                    } else {
                        Log.info(#file, "Sign-in cancelled or failed for '\(book.title)' - cleaning up download state")
                        // Clean up download coordinator since we registered a start but won't proceed
                        await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
                    }
                }
            }
        }
    }
}
