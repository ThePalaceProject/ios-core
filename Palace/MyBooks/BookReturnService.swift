//
//  BookReturnService.swift
//  Palace
//
//  Owns the borrow-return business flow that lived inside
//  MyBooksDownloadCenter as `returnBook(withIdentifier:completion:)` (~230
//  LOC of nested error handling: Adobe DRM return, OPDS revoke fetch,
//  PalaceError.parsing fallback, no-active-loan / loan-term-limit cleanup,
//  invalid-credentials re-auth + retry, generic alert with
//  retry/remove-from-device/cancel actions).
//
//  Extracted so the return state machine can be reasoned about and
//  exercised in isolation. MBDC keeps the same `returnBook(withIdentifier:
//  completion:)` @objc surface as a 1-line delegator — preserves all
//  external callers (UI, BookDetailViewModel, MyBooksViewModel, etc.).
//

import Foundation
import UIKit
import PalaceLogging
import PalaceCatalog

// MARK: - BookReturnServiceDelegate

/// Surface MBDC needs to expose so the service can clean local content
/// + audiobook caches as part of the return cleanup. Both already exist
/// on MBDC's surface; conformance is empty.
protocol BookReturnServiceDelegate: AnyObject {
    /// Force-purge all audiobook caches. Called after every successful
    /// return path so abandoned audiobook chunks don't linger on disk.
    func purgeAllAudiobookCaches(force: Bool)
}

// MARK: - BookReturnService

/// Coordinates the return-loan flow with the circulation manager.
final class BookReturnService {

    weak var delegate: BookReturnServiceDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let localContentService: LocalBookContentService
    private let opdsFeedService: OPDSFeedFetching
    private let downloadAnnouncementService: DownloadAnnouncementService
    private let bookmarkDeletionLog: TPPBookmarkDeletionLog
    private let reauthenticator: Reauthenticator
    private let userRetryTracker: UserRetryTracker

    /// Closure resolves the current user account each call so library
    /// switches mid-flow are observed correctly (matches MBDC's `userAccount`
    /// computed property semantics).
    private let userAccountProvider: () -> TPPUserAccount

    /// Adobe DRM service stored property gated on FEATURE_DRM_CONNECTOR
    /// (the type itself is gated). In Palace-noDRM the property doesn't
    /// exist and the Adobe-return code path is compiled out.
    #if FEATURE_DRM_CONNECTOR
    private let adobeDRMService: AdobeDRMService
    #endif

    #if FEATURE_DRM_CONNECTOR
    init(
        bookRegistry: TPPBookRegistryProvider,
        localContentService: LocalBookContentService,
        opdsFeedService: OPDSFeedFetching,
        downloadAnnouncementService: DownloadAnnouncementService,
        bookmarkDeletionLog: TPPBookmarkDeletionLog,
        reauthenticator: Reauthenticator,
        userRetryTracker: UserRetryTracker,
        userAccountProvider: @escaping () -> TPPUserAccount,
        adobeDRMService: AdobeDRMService = .shared
    ) {
        self.bookRegistry = bookRegistry
        self.localContentService = localContentService
        self.opdsFeedService = opdsFeedService
        self.downloadAnnouncementService = downloadAnnouncementService
        self.bookmarkDeletionLog = bookmarkDeletionLog
        self.reauthenticator = reauthenticator
        self.userRetryTracker = userRetryTracker
        self.userAccountProvider = userAccountProvider
        self.adobeDRMService = adobeDRMService
    }
    #else
    init(
        bookRegistry: TPPBookRegistryProvider,
        localContentService: LocalBookContentService,
        opdsFeedService: OPDSFeedFetching,
        downloadAnnouncementService: DownloadAnnouncementService,
        bookmarkDeletionLog: TPPBookmarkDeletionLog,
        reauthenticator: Reauthenticator,
        userRetryTracker: UserRetryTracker,
        userAccountProvider: @escaping () -> TPPUserAccount
    ) {
        self.bookRegistry = bookRegistry
        self.localContentService = localContentService
        self.opdsFeedService = opdsFeedService
        self.downloadAnnouncementService = downloadAnnouncementService
        self.bookmarkDeletionLog = bookmarkDeletionLog
        self.reauthenticator = reauthenticator
        self.userRetryTracker = userRetryTracker
        self.userAccountProvider = userAccountProvider
    }
    #endif

    // MARK: - returnBook

    func returnBook(withIdentifier identifier: String, completion: (() -> Void)? = nil) {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            completion?()
            return
        }

        downloadAnnouncementService.announceReturnStarted(for: book)

        let state = bookRegistry.state(for: identifier)
        let downloaded = (state == .downloadSuccessful) || (state == .used)

        // Process Adobe Return
        #if FEATURE_DRM_CONNECTOR
        let userAccount = userAccountProvider()
        if let fulfillmentId = bookRegistry.fulfillmentId(forIdentifier: identifier),
           userAccount.authDefinition?.needsAuth == true {
            NSLog("Return attempt for book. userID: %@", userAccount.userID ?? "")
            self.adobeDRMService.returnLoan(fulfillmentId,
                                            userID: userAccount.userID,
                                            deviceID: userAccount.deviceID) { success, _ in
                if !success {
                    NSLog("Failed to return loan via NYPLAdept.")
                }
            }
        }
        #endif

        if book.revokeURL == nil {
            handleReturnWithoutRevokeURL(book: book, identifier: identifier, downloaded: downloaded, completion: completion)
            return
        }

        bookRegistry.setProcessing(true, for: book.identifier)

        Task { [weak self] in
            guard let self, let revokeURL = book.revokeURL else {
                await MainActor.run {
                    self?.bookRegistry.setProcessing(false, for: book.identifier)
                    self?.downloadAnnouncementService.announceReturnFailed(for: book)
                    completion?()
                }
                return
            }

            do {
                let feed = try await self.opdsFeedService.fetchFeed(from: revokeURL)
                await MainActor.run {
                    self.bookRegistry.setProcessing(false, for: book.identifier)
                }

                guard feed.entries.count == 1, let entry = feed.entries[0] as? TPPOPDSEntry else {
                    Log.error(#file, "Revoke response had \(feed.entries.count) entries, expected 1")
                    await MainActor.run {
                        self.downloadAnnouncementService.announceReturnFailed(for: book)
                        completion?()
                    }
                    return
                }

                guard let returnedBook = TPPBook(entry: entry) else {
                    Log.error(#file, "Failed to create book from revoke entry")
                    await MainActor.run {
                        self.downloadAnnouncementService.announceReturnFailed(for: book)
                        completion?()
                    }
                    return
                }

                if downloaded {
                    self.localContentService.deleteLocalContent(for: identifier)
                    self.delegate?.purgeAllAudiobookCaches(force: true)
                }

                TPPAnnotations.deleteAllBookmarks(forBook: book) {
                    self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                    self.bookRegistry.updateAndRemoveBook(returnedBook)
                    self.bookRegistry.setState(.unregistered, for: identifier)
                    self.performPostReturnSyncThen {
                        self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                        completion?()
                    }
                }

            } catch {
                await MainActor.run {
                    self.bookRegistry.setProcessing(false, for: book.identifier)
                }

                self.handleRevokeError(error, book: book, identifier: identifier, downloaded: downloaded, completion: completion)
            }
        }
    }

    // MARK: - Private branches

    /// Books without a revokeURL skip the OPDS round trip entirely —
    /// just clear local content + bookmarks + remove the book from the
    /// registry, then sync.
    private func handleReturnWithoutRevokeURL(book: TPPBook, identifier: String, downloaded: Bool, completion: (() -> Void)?) {
        if downloaded {
            localContentService.deleteLocalContent(for: identifier)
            delegate?.purgeAllAudiobookCaches(force: true)
        }

        // Delete all server bookmarks before removing book to prevent
        // old bookmarks from reappearing when the book is re-borrowed
        TPPAnnotations.deleteAllBookmarks(forBook: book) { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            // Clear the deletion log since we're returning the book
            self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
            self.bookRegistry.setState(.unregistered, for: identifier)
            self.bookRegistry.removeBook(forIdentifier: identifier)
            self.performPostReturnSyncThen {
                self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                completion?()
            }
        }
    }

    /// Failure path branches: parsing-error-as-success, no-active-loan +
    /// loan-term-limit cleanup, invalid-credentials re-auth retry, or
    /// generic alert with retry / remove-from-device / cancel.
    private func handleRevokeError(_ error: Error, book: TPPBook, identifier: String, downloaded: Bool, completion: (() -> Void)?) {
        // The OverDrive revoke endpoint returns XML that isn't a
        // valid OPDS feed (e.g., a simple success response). The
        // OPDS parser rejects it → PalaceError.parsing(.opdsFeedInvalid).
        // The revoke likely SUCCEEDED server-side — clean up locally
        // and sync to confirm, rather than showing an error.
        if case .parsing(.opdsFeedInvalid) = error as? PalaceError {
            Log.info(#file, "Revoke response was not a valid OPDS feed — treating as success and syncing to verify")
            if downloaded {
                localContentService.deleteLocalContent(for: identifier)
                delegate?.purgeAllAudiobookCaches(force: true)
            }
            TPPAnnotations.deleteAllBookmarks(forBook: book) { [weak self] in
                guard let self else { return }
                self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                self.bookRegistry.setState(.unregistered, for: identifier)
                self.bookRegistry.removeBook(forIdentifier: identifier)
                self.performPostReturnSyncThen {
                    self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                    completion?()
                }
            }
            return
        }

        // Extract problem document from the typed error
        let problemDoc = (error as NSError).problemDocument
        let problemType = problemDoc?.type

        Log.error(#file, "Return failed for '\(book.title)': \(error.localizedDescription), problemDoc type: \(problemType ?? "nil")")

        // Loan already gone on server — clean up locally
        let isLoanGone = problemType == TPPProblemDocument.TypeNoActiveLoan
            || (problemDoc?.detail?.contains(TPPProblemDocument.DetailLoanTermLimitReached) == true)

        if isLoanGone {
            if downloaded {
                localContentService.deleteLocalContent(for: identifier)
                delegate?.purgeAllAudiobookCaches(force: true)
            }
            TPPAnnotations.deleteAllBookmarks(forBook: book) { [weak self] in
                guard let self else { return }
                self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                self.bookRegistry.setState(.unregistered, for: identifier)
                self.bookRegistry.removeBook(forIdentifier: identifier)
                self.performPostReturnSyncThen {
                    self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                    completion?()
                }
            }
            return
        }

        // Auth error — re-authenticate and retry. Mirrors BorrowOperation's
        // detection logic so SAML/OIDC token expiry on return surfaces the
        // same sign-in modal that borrow already shows. Without the broader
        // detection, an expired SAML bearer token returned a generic 401
        // (no `invalid-credentials` problem-doc type) and fell through to
        // the alert path, contradicting the borrow UX.
        let nsError = error as NSError
        let isAuthError: Bool = {
            if problemType == TPPProblemDocument.TypeInvalidCredentials { return true }
            if problemDoc?.isRecoverableAuthError == true { return true }
            if nsError.code == TPPErrorCode.invalidCredentials.rawValue { return true }
            return false
        }()

        if isAuthError {
            let userAccount = userAccountProvider()
            let authDef = userAccount.authDefinition
            let needsBrowserReauth = (authDef?.isSaml == true || authDef?.isOidc == true)
                && userAccount.hasCredentials()

            if needsBrowserReauth {
                // Force the SignInModal to drive a fresh browser auth instead
                // of silently reusing the expired credentials.
                Log.info(#file, "Auth error on return for SAML/OIDC account — marking credentials stale and presenting re-auth modal")
                userAccount.markCredentialsStale()
            } else {
                Log.info(#file, "Auth error on return — triggering re-auth")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let user = self.userAccountProvider()
                self.reauthenticator.authenticateIfNeeded(user, usingExistingCredentials: false) { [weak self] in
                    guard let self else { return }
                    if self.userAccountProvider().hasCredentials() {
                        self.returnBook(withIdentifier: identifier, completion: completion)
                    } else {
                        runOnMainAsync {
                            self.downloadAnnouncementService.announceReturnFailed(for: book)
                            completion?()
                        }
                    }
                }
            }
            return
        }

        // All other errors — show alert with problem document if available
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.presentReturnFailureAlert(
                error: error,
                problemDoc: problemDoc,
                book: book,
                identifier: identifier,
                downloaded: downloaded,
                completion: completion
            )
        }
    }

    @MainActor
    private func presentReturnFailureAlert(
        error: Error,
        problemDoc: TPPProblemDocument?,
        book: TPPBook,
        identifier: String,
        downloaded: Bool,
        completion: (() -> Void)?
    ) {
        let serverDetail = problemDoc?.detail
            ?? (error as NSError).userInfo["problemDocumentDetail"] as? String
            ?? error.localizedDescription
        let formattedMessage = String(format: Strings.MyDownloadCenter.returnFailedMessage, book.title)
            + "\n\n" + serverDetail

        let operationId = "return-\(identifier)"
        let retryAction: (() -> Void)? = {
            guard self.userRetryTracker.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                guard let self else { return }
                self.userRetryTracker.recordRetry(operationId: operationId)
                self.returnBook(withIdentifier: identifier, completion: completion)
            }
        }()

        let message = (retryAction == nil && !userRetryTracker.canRetry(operationId: operationId))
            ? Strings.MyDownloadCenter.tryAgainLater
            : formattedMessage

        let alert = UIAlertController(title: Strings.MyDownloadCenter.returnFailed, message: message, preferredStyle: .alert)

        if let retryAction = retryAction {
            alert.addAction(UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { _ in retryAction() })
        }

        alert.addAction(UIAlertAction(title: NSLocalizedString("Remove from Device", comment: "Button to remove a book locally when server return fails"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            if downloaded {
                self.localContentService.deleteLocalContent(for: identifier)
                self.delegate?.purgeAllAudiobookCaches(force: true)
            }
            self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
            self.bookRegistry.setState(.unregistered, for: identifier)
            self.bookRegistry.removeBook(forIdentifier: identifier)
            self.downloadAnnouncementService.announceReturnSucceeded(for: book)
            completion?()
        })

        alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))

        if let doc = problemDoc {
            TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: true)
        }

        TPPPresentationUtils.safelyPresent(alert)
        downloadAnnouncementService.announceReturnFailed(for: book)
        completion?()
    }

    // MARK: - Post-return sync

    /// Performs a registry sync after a return. On failure, posts
    /// `TPPSyncFailed` so the Reservations tab can show the sync error
    /// banner; completion is always called so the return UI is dismissed.
    private func performPostReturnSyncThen(completion: @escaping () -> Void) {
        Task { [weak self] in
            do {
                // Use the injected `bookRegistry` rather than reaching into
                // AppContainer here, so unit tests can substitute a registry
                // double. `syncAsync` is defined on the concrete
                // `TPPBookRegistry` rather than the protocol; the cast is
                // safe in production where `bookRegistry` is always the
                // app-scoped instance constructed by AppContainer._cached.
                if let registry = self?.bookRegistry as? TPPBookRegistry {
                    _ = try await registry.syncAsync()
                }
            } catch {
                Log.error(#file, "Post-return sync failed: \(error.localizedDescription)")
                NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)
            }
            runOnMainAsync(completion)
        }
    }
}
