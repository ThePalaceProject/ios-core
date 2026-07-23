//
//  DownloadStartDispatcher.swift
//  Palace
//
//  Owns the start-download dispatch flow lifted out of
//  MyBooksDownloadCenter as part of the Phase 7 decomposition.
//
//  Three entry points, called from MBDC's startDownloadAsync after the
//  active-cap / throttling / credential-prompt branches have settled:
//
//  - processUnregisteredState: pure state-seed for unregistered books
//    whose acquisition is open-access (or doesn't require login).
//    Returns the new TPPBookState; MBDC continues with that state.
//  - processDownloadWithCredentials: routes a credentialed request.
//    Borrow/hold states go to startBorrow; Overdrive audiobooks go to
//    deferOverdriveFulfillment / processOverdriveDownload via the
//    OverdriveDownloadHandler; everything else falls through to
//    processRegularDownload.
//  - processRegularDownload (internal): handles re-borrow on expired
//    books, auto-borrow on downloadNeeded-with-borrow-link, the
//    Wi-Fi-only guard, request resolution + bearer auth, the SAML
//    cookies branch, and the addDownloadTask handoff.
//
//  logInvalidURLRequest stays on MBDC (UIKit + cookies-webview-controller
//  presentation) and is invoked through the delegate.
//

import Foundation
import PalacePreferences
import PalaceLogging

// MARK: - Delegate

protocol DownloadStartDispatcherDelegate: AnyObject {
    var bookRegistry: TPPBookRegistryProvider { get }
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
    func addDownloadTask(with request: URLRequest, book: TPPBook)
    func clearAndSetCookies()
    func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie])
    func failWithWifiRequired(for book: TPPBook)
    func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?)
}

// MARK: - DownloadStartDispatcher

final class DownloadStartDispatcher {

    weak var delegate: DownloadStartDispatcherDelegate?

    private let userAccountProvider: () -> TPPUserAccount
    /// Applies the bearer token to an outbound URLRequest using the
    /// download's CAPTURED accountId — never `currentUserAccount`. This is
    /// the injection seam that lets Module A close the library-swap-mid-
    /// download window without standing up the full network executor in
    /// tests. Production wires this to
    /// `networkExecutor.bearerAuthorized(request:accountId:)`; tests pass a
    /// recorder closure to assert which accountId reached the request.
    private let applyBearerAuth: (URLRequest, String) -> URLRequest
    private let settings: TPPSettings
    private let isOnWiFi: () -> Bool
    private let memoryPressureMonitor: MemoryPressureMonitor
    #if FEATURE_OVERDRIVE
    private let overdriveHandler: OverdriveDownloadHandler
    #endif

    private var userAccount: TPPUserAccount { userAccountProvider() }

    /// True when the user has Wi-Fi-only mode on AND the device is not
    /// currently on Wi-Fi. Mirrors `MyBooksDownloadCenter.isWifiOnlyEnforced`.
    private var isWifiOnlyEnforced: Bool {
        settings.downloadOnlyOnWiFi && !isOnWiFi()
    }

    #if FEATURE_OVERDRIVE
    init(
        userAccountProvider: @escaping () -> TPPUserAccount,
        applyBearerAuth: @escaping (URLRequest, String) -> URLRequest,
        settings: TPPSettings,
        isOnWiFi: @escaping () -> Bool,
        memoryPressureMonitor: MemoryPressureMonitor,
        overdriveHandler: OverdriveDownloadHandler
    ) {
        self.userAccountProvider = userAccountProvider
        self.applyBearerAuth = applyBearerAuth
        self.settings = settings
        self.isOnWiFi = isOnWiFi
        self.memoryPressureMonitor = memoryPressureMonitor
        self.overdriveHandler = overdriveHandler
    }
    /// Legacy convenience init for pre-Module-A test call sites — defaults
    /// `applyBearerAuth` to the legacy class-func bearer applier (the no-arg
    /// resolver-fallback overload). Tests that assert routing-only behavior
    /// don't exercise the captured-accountId semantics and don't care which
    /// applier fires; tests that DO care override this seam explicitly.
    convenience init(
        userAccountProvider: @escaping () -> TPPUserAccount,
        settings: TPPSettings,
        isOnWiFi: @escaping () -> Bool,
        memoryPressureMonitor: MemoryPressureMonitor,
        overdriveHandler: OverdriveDownloadHandler
    ) {
        self.init(
            userAccountProvider: userAccountProvider,
            applyBearerAuth: { req, _ in TPPNetworkExecutor.bearerAuthorized(request: req) },
            settings: settings,
            isOnWiFi: isOnWiFi,
            memoryPressureMonitor: memoryPressureMonitor,
            overdriveHandler: overdriveHandler
        )
    }
    #else
    init(
        userAccountProvider: @escaping () -> TPPUserAccount,
        applyBearerAuth: @escaping (URLRequest, String) -> URLRequest,
        settings: TPPSettings,
        isOnWiFi: @escaping () -> Bool,
        memoryPressureMonitor: MemoryPressureMonitor
    ) {
        self.userAccountProvider = userAccountProvider
        self.applyBearerAuth = applyBearerAuth
        self.settings = settings
        self.isOnWiFi = isOnWiFi
        self.memoryPressureMonitor = memoryPressureMonitor
    }
    /// Legacy convenience init for pre-Module-A test call sites — defaults
    /// `applyBearerAuth` to the legacy class-func bearer applier.
    convenience init(
        userAccountProvider: @escaping () -> TPPUserAccount,
        settings: TPPSettings,
        isOnWiFi: @escaping () -> Bool,
        memoryPressureMonitor: MemoryPressureMonitor
    ) {
        self.init(
            userAccountProvider: userAccountProvider,
            applyBearerAuth: { req, _ in TPPNetworkExecutor.bearerAuthorized(request: req) },
            settings: settings,
            isOnWiFi: isOnWiFi,
            memoryPressureMonitor: memoryPressureMonitor
        )
    }
    #endif

    // MARK: - Public entry points

    func processUnregisteredState(
        for book: TPPBook,
        location: TPPBookLocation?,
        loginRequired: Bool?
    ) -> TPPBookState {
        guard let delegate else { return .unregistered }
        let decision = DownloadStartReducer.reduceUnregistered(
            .init(
                hasBorrowLink: book.defaultAcquisitionIfBorrow != nil,
                hasOpenAccess: book.defaultAcquisitionIfOpenAccess != nil,
                loginRequired: loginRequired ?? false
            )
        )
        switch decision {
        case .seedDownloadNeeded:
            delegate.bookRegistry.addBook(
                book,
                location: location,
                state: .downloadNeeded,
                fulfillmentId: nil,
                readiumBookmarks: nil,
                genericBookmarks: nil
            )
            return .downloadNeeded
        case .stayUnregistered:
            return .unregistered
        }
    }

    /// Legacy 3-arg overload retained for pre-Module-A test call sites that
    /// don't thread a captured accountId. Delegates to the 4-arg variant
    /// using the sentinel — appropriate for routing-shape tests that don't
    /// assert bearer-auth semantics.
    func processDownloadWithCredentials(
        for book: TPPBook,
        withState state: TPPBookState,
        andRequest initedRequest: URLRequest?
    ) {
        processDownloadWithCredentials(
            for: book,
            withState: state,
            andRequest: initedRequest,
            capturedAccountId: DownloadStartCoordinator.capturedNoAccountSentinelUUID
        )
    }

    /// Captured-accountId variant — `capturedAccountId` is the library UUID
    /// pinned by `DownloadStartCoordinator.startDownloadAsync` at the very
    /// first line of the path. Threads through to the bearer-auth step so
    /// the resulting URLRequest carries credentials for the originally-
    /// selected library, even if the user library-swaps mid-flight.
    func processDownloadWithCredentials(
        for book: TPPBook,
        withState state: TPPBookState,
        andRequest initedRequest: URLRequest?,
        capturedAccountId: String
    ) {
        guard let delegate else { return }
        // PP-4161 Wave 4 (Path X): streaming-HTML titles are online-only — no
        // local asset to download; the borrow-state route needs a borrow before
        // download; Overdrive audiobooks divert to the fulfillment handler.
        // The branch SELECTION lives in `DownloadStartReducer.routeWithCredentials`;
        // this method runs the chosen effect. `#if FEATURE_OVERDRIVE` gates only
        // the precomputed Bool + the handler call, never the pure route logic.
        #if FEATURE_OVERDRIVE
        let isOverdriveAudiobook = book.distributor == OverdriveDistributorKey
            && book.defaultBookContentType == .audiobook
        let shouldDeferOverdrive = isOverdriveAudiobook
            && MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for: book, state: state)
        #else
        let isOverdriveAudiobook = false
        let shouldDeferOverdrive = false
        #endif

        let route = DownloadStartReducer.routeWithCredentials(
            .init(
                isStreamingHTML: book.defaultBookContentType == .streamingHTML,
                state: state,
                isOverdriveAudiobook: isOverdriveAudiobook,
                shouldDeferOverdrive: shouldDeferOverdrive
            )
        )

        switch route {
        case .noop:
            return
        case .startBorrow:
            delegate.startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
            return
        case .deferOverdrive:
            #if FEATURE_OVERDRIVE
            overdriveHandler.deferOverdriveFulfillment(for: book)
            #endif
            return
        case .processOverdrive:
            #if FEATURE_OVERDRIVE
            overdriveHandler.processOverdriveDownload(for: book, withState: state)
            #endif
            return
        case .fallThroughToRegular:
            processRegularDownload(for: book, withState: state, andRequest: initedRequest, capturedAccountId: capturedAccountId)
        }
    }

    // MARK: - Internal

    /// Legacy 3-arg overload — delegates to the captured-accountId variant
    /// with the noAccountSentinelUUID. Preserves call-site compatibility for
    /// tests + ObjC bridges written before Module A's accountId threading.
    func processRegularDownload(
        for book: TPPBook,
        withState state: TPPBookState,
        andRequest initedRequest: URLRequest?
    ) {
        processRegularDownload(
            for: book,
            withState: state,
            andRequest: initedRequest,
            capturedAccountId: DownloadStartCoordinator.capturedNoAccountSentinelUUID
        )
    }

    func processRegularDownload(
        for book: TPPBook,
        withState state: TPPBookState,
        andRequest initedRequest: URLRequest?,
        capturedAccountId: String
    ) {
        guard let delegate else { return }

        // The `book` parameter might be stale (e.g. from before a borrow
        // completed). Re-resolve through the registry so the acquisition
        // links and rights bits reflect the current loan.
        let currentBook = delegate.bookRegistry.book(forIdentifier: book.identifier) ?? book

        // Branch SELECTION + effect ORDER live in the pure reducer; this method
        // executes each decided effect (logging, request construction, cookie
        // resolution, and delegate calls stay here — the runner owns I/O).
        let samlWithCookies = (state == .SAMLStarted) && (userAccount.cookies != nil)
        let plan = DownloadStartReducer.reduceRegular(
            .init(
                state: state,
                isExpired: currentBook.isExpired,
                hasBorrowLink: currentBook.defaultAcquisitionIfBorrow != nil,
                wifiOnlyEnforced: isWifiOnlyEnforced,
                hasInitedRequest: initedRequest != nil,
                hasAcquisitionURL: currentBook.defaultAcquisition?.hrefURL != nil,
                samlWithCookies: samlWithCookies
            )
        )

        // Lazily built once, only when a download-tail effect needs it. The
        // reducer has already established that a request source exists.
        func resolveRequest() -> URLRequest? {
            if let initedRequest { return initedRequest }
            guard let url = currentBook.defaultAcquisition?.hrefURL else { return nil }
            // Captured-accountId path: feed the pinned accountId into the
            // bearer-auth applier so the resulting Authorization header matches
            // the library selected at download START, not whatever
            // `currentUserAccount` resolves to at request-build time.
            return applyBearerAuth(
                URLRequest(url: url, applyingCustomUserAgent: true),
                capturedAccountId
            )
        }

        for effect in plan {
            switch effect {
            case .setStateUnregistered:
                if currentBook.isExpired {
                    Log.warn(#file, "Book \(book.identifier) is expired. Attempting to re-borrow before download.")
                } else {
                    Log.info(#file, "Book \(book.identifier) is downloadNeeded with borrow acquisition - auto-borrowing before download")
                }
                delegate.bookRegistry.setState(.unregistered, for: book.identifier)

            case let .startBorrow(attemptDownload, withCompletion):
                if withCompletion {
                    delegate.startBorrow(for: currentBook, attemptDownload: attemptDownload) { [weak delegate] in
                        guard let delegate else { return }
                        let newState = delegate.bookRegistry.state(for: book.identifier)
                        Log.debug(#file, "Auto-borrow completed for \(book.identifier), new state: \(newState)")
                        if newState != .downloading && newState != .downloadSuccessful && newState != .downloadNeeded {
                            Log.warn(#file, "Auto-borrow completed but book is not downloadable, state: \(newState)")
                        }
                    }
                } else {
                    delegate.startBorrow(for: currentBook, attemptDownload: attemptDownload, borrowCompletion: nil)
                }

            case .failWifi:
                delegate.failWithWifiRequired(for: currentBook)

            case let .logInvalidRequest(hasURL):
                delegate.logInvalidURLRequest(
                    for: currentBook, withState: state,
                    url: hasURL ? currentBook.defaultAcquisition?.hrefURL : nil,
                    request: nil
                )

            case .reclaimDiskSpace:
                // Reclaim space only when free disk is genuinely low — mirrors
                // the pre-extraction unconditional pre-download call.
                memoryPressureMonitor.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 512)

            case .handleSAML:
                guard let request = resolveRequest(), request.url != nil else {
                    delegate.logInvalidURLRequest(for: currentBook, withState: state, url: currentBook.defaultAcquisition?.hrefURL, request: nil)
                    return
                }
                Log.info(#file, "SAML authentication flow for '\(currentBook.title)'")
                delegate.handleSAMLStartedState(for: currentBook, withRequest: request, cookies: userAccount.cookies ?? [])

            case .clearAndSetCookies:
                if userAccount.authToken != nil {
                    Log.debug(#file, "Auth token present for '\(currentBook.title)', proceeding with download")
                } else if userAccount.cookies != nil {
                    Log.debug(#file, "Using saved SAML cookies for '\(currentBook.title)', proceeding with download")
                }
                delegate.clearAndSetCookies()

            case .addDownloadTask:
                guard let request = resolveRequest(), request.url != nil else {
                    delegate.logInvalidURLRequest(for: currentBook, withState: state, url: currentBook.defaultAcquisition?.hrefURL, request: nil)
                    return
                }
                delegate.addDownloadTask(with: request, book: currentBook)
            }
        }
    }
}
