//
//  OverdriveDownloadHandler.swift
//  Palace
//
//  Owns the Overdrive-specific fulfillment workflow that lived inside
//  MyBooksDownloadCenter as `processOverdriveDownload` /
//  `handleOverdriveResponse` / `deferOverdriveFulfillment`. Overdrive
//  audiobook fulfillment is a 302-redirect dance: the API returns
//  headers carrying `x-overdrive-scope` + `x-overdrive-patron-
//  authorization` + `location`, which we use to build a manifest
//  request. The defer path covers the case where the borrow flow
//  routes us to fulfillment before the loans feed has settled — we
//  resync the registry and surface a "loan already exists" notice.
//
//  Whole class is gated `#if FEATURE_OVERDRIVE` because
//  `OverdriveAPIExecutor` lives in the OverdriveProcessor module
//  which only compiles in Overdrive-enabled builds.
//

#if FEATURE_OVERDRIVE

import Foundation
import OverdriveProcessor
import PalaceLogging

// MARK: - OverdriveDownloadHandlerDelegate

/// Surface MBDC needs to expose so the handler can ask whether
/// downloads are gated on Wi-Fi, fail gracefully when they are, and
/// hand off the manifest request to the URL session pipeline.
protocol OverdriveDownloadHandlerDelegate: AnyObject {
    var isWifiOnlyEnforced: Bool { get }
    func failWithWifiRequired(for book: TPPBook)
    func addDownloadTask(with request: URLRequest, book: TPPBook)
}

// MARK: - OverdriveDownloadHandler

/// Coordinates the Overdrive fulfillment redirect → manifest-fetch
/// flow, plus the loans-feed-out-of-sync defer path.
final class OverdriveDownloadHandler {

    typealias DisplayStrings = Strings.MyDownloadCenter

    weak var delegate: OverdriveDownloadHandlerDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let stateManager: DownloadStateManager
    private let progressReporter: DownloadProgressReporter
    private let alertPresenter: DownloadAlertPresenter
    private let userAccountProvider: () -> TPPUserAccount

    /// Closure that performs the Overdrive fulfillment redirect request.
    /// Production wires `OverdriveAPIExecutor.shared.fulfillBook(...)`.
    /// Tests stub this to capture the completion handler so they can
    /// drive the success / error / missing-headers branches without a
    /// live Overdrive API. Mirrors the closure-injection pattern used
    /// in `CredentialPromptCoordinator.presentSignInModal`.
    ///
    /// The completion signature uses `Error?` (not `NSError?`) so the
    /// handler's existing closure shape (`([AnyHashable: Any]?, Error?)`)
    /// flows through unchanged. The Obj-C bridge between
    /// `OverdriveAPIExecutor`'s `NSError?` parameter and `Error?` is
    /// transparent.
    private let fulfillBookRequest: (_ urlString: String,
                                     _ authType: AuthType,
                                     _ completion: @escaping ([AnyHashable: Any]?, Error?) -> Void) -> Void

    /// Closure that builds the manifest URLRequest from the redirect
    /// headers. Production wires
    /// `OverdriveAPIExecutor.shared.getManifestRequest(...)`. Tests stub
    /// this to return a synthetic request (or nil to exercise the
    /// "wrong headers" parse-fail branch).
    private let manifestRequestFactory: (_ urlString: String,
                                         _ token: String,
                                         _ scope: String) -> URLRequest?

    init(
        bookRegistry: TPPBookRegistryProvider,
        stateManager: DownloadStateManager,
        progressReporter: DownloadProgressReporter,
        alertPresenter: DownloadAlertPresenter,
        userAccountProvider: @escaping () -> TPPUserAccount,
        fulfillBookRequest: @escaping (_ urlString: String,
                                       _ authType: AuthType,
                                       _ completion: @escaping ([AnyHashable: Any]?, Error?) -> Void) -> Void = { urlString, authType, completion in
            OverdriveAPIExecutor.shared.fulfillBook(urlString: urlString, authType: authType) { (headers: [String: Any]?, nsError: NSError?) in
                let bridged: [AnyHashable: Any]? = headers.map { dict in
                    Dictionary(uniqueKeysWithValues: dict.map { (AnyHashable($0.key), $0.value) })
                }
                completion(bridged, nsError)
            }
        },
        manifestRequestFactory: @escaping (_ urlString: String,
                                           _ token: String,
                                           _ scope: String) -> URLRequest? = { urlString, token, scope in
            OverdriveAPIExecutor.shared.getManifestRequest(urlString: urlString, token: token, scope: scope)
        }
    ) {
        self.bookRegistry = bookRegistry
        self.stateManager = stateManager
        self.progressReporter = progressReporter
        self.alertPresenter = alertPresenter
        self.userAccountProvider = userAccountProvider
        self.fulfillBookRequest = fulfillBookRequest
        self.manifestRequestFactory = manifestRequestFactory
    }

    // MARK: - Defer (loans-feed-out-of-sync)

    /// Called when the borrow flow routes us to fulfillment but the
    /// `defaultAcquisition` is still a borrow link — i.e. the server's
    /// loan record hasn't replicated to our local registry yet. Resync
    /// the registry and surface a "loan already exists" notice.
    func deferOverdriveFulfillment(for book: TPPBook) {
        Log.warn(#file, "Overdrive audiobook '\(book.title)' routed to fulfillment but default acquisition is still borrow — deferring and syncing loans feed")
        Task { [weak self] in
            await self?.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
        }
        bookRegistry.sync()
        runOnMainAsync { [weak self] in
            self?.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(
                    bookId: book.identifier,
                    title: DisplayStrings.borrowFailed,
                    message: DisplayStrings.loanAlreadyExistsAlertMessage,
                    kind: .borrow
                )
            )
        }
    }

    // MARK: - Fulfillment

    /// Kicks off the Overdrive fulfillment request for `book`. Gates on
    /// Wi-Fi-only mode first; on success the response headers will
    /// carry the redirect data we feed into `handleOverdriveResponse`.
    func processOverdriveDownload(for book: TPPBook, withState state: TPPBookState) {
        if delegate?.isWifiOnlyEnforced == true {
            delegate?.failWithWifiRequired(for: book)
            return
        }

        guard let url = book.defaultAcquisition?.hrefURL else { return }

        let completion: ([AnyHashable: Any]?, Error?) -> Void = { [weak self] responseHeaders, error in
            self?.handleOverdriveResponse(for: book, url: url, withState: state, responseHeaders: responseHeaders, error: error)
        }

        let userAccount = userAccountProvider()
        if let token = userAccount.authToken {
            fulfillBookRequest(url.absoluteString, .token(token), completion)
        } else if let username = userAccount.username, let pin = userAccount.PIN {
            fulfillBookRequest(url.absoluteString, .basic(username: username, pin: pin), completion)
        }
    }

    /// Parses the Overdrive fulfillment response — extracts the scope +
    /// patron-authorization + redirect URL from the response headers
    /// and builds a manifest request for the URL session pipeline. Any
    /// missing header surfaces a download-failed alert.
    func handleOverdriveResponse(
        for book: TPPBook,
        url: URL?,
        withState state: TPPBookState,
        responseHeaders: [AnyHashable: Any]?,
        error: Error?
    ) {
        let summaryWrongHeaders = "Overdrive audiobook fulfillment: wrong headers"
        let nA = "N/A"
        let responseHeadersKey = "responseHeaders"
        let acquisitionURLKey = "acquisitionURL"
        let bookKey = "book"
        let bookRegistryStateKey = "bookRegistryState"

        if let error = error {
            let summary = "Overdrive audiobook fulfillment error"

            TPPErrorLogger.logError(error, summary: summary, metadata: [
                responseHeadersKey: responseHeaders ?? nA,
                acquisitionURLKey: url?.absoluteString ?? nA,
                bookKey: book.loggableDictionary,
                bookRegistryStateKey: TPPBookStateHelper.stringValue(from: state)
            ])
            alertPresenter.failDownloadWithAlert(for: book, withMessage: nil)
            return
        }

        let normalizedHeaders = responseHeaders?.mapKeys { String(describing: $0).lowercased() }
        let scopeKey = "x-overdrive-scope"
        let patronAuthorizationKey = "x-overdrive-patron-authorization"
        let locationKey = "location"

        guard let scope = normalizedHeaders?[scopeKey] as? String,
              let patronAuthorization = normalizedHeaders?[patronAuthorizationKey] as? String,
              let requestURLString = normalizedHeaders?[locationKey] as? String,
              let request = manifestRequestFactory(requestURLString, patronAuthorization, scope)
        else {
            TPPErrorLogger.logError(withCode: .overdriveFulfillResponseParseFail, summary: summaryWrongHeaders, metadata: [
                responseHeadersKey: responseHeaders ?? nA,
                acquisitionURLKey: url?.absoluteString ?? nA,
                bookKey: book.loggableDictionary,
                bookRegistryStateKey: TPPBookStateHelper.stringValue(from: state)
            ])
            alertPresenter.failDownloadWithAlert(for: book, withMessage: nil)
            return
        }

        delegate?.addDownloadTask(with: request, book: book)
    }
}

#endif
