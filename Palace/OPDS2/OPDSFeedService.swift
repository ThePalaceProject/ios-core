//
//  OPDSFeedService.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceCatalog

/// Narrow protocol that BookReturnService and similar callers depend on so
/// tests can substitute a fixture / failing fetcher without standing up the
/// full actor + URL stack. Production code passes an OPDSFeedService instance
/// that satisfies this protocol via the conformance below.
protocol OPDSFeedFetching: Sendable {
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed
}

/// Modern async/await service for OPDS feed operations
/// Wraps legacy Objective-C TPPOPDSFeed with type-safe async API
actor OPDSFeedService: OPDSFeedFetching {

    private var inflightRequests: [URL: Task<TPPOPDSFeed, Error>] = [:]

    init() {}

    // MARK: - Feed Fetching

    /// `OPDSFeedFetching` conformance — single-arg form so callers can
    /// depend on the narrow protocol instead of the full actor surface.
    /// Delegates to the canonical 3-arg method with production defaults.
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        try await fetchFeed(from: url, resetCache: false, useToken: true)
    }

    /// Fetches an OPDS feed from the given URL
    /// - Parameters:
    ///   - url: The URL to fetch from
    ///   - resetCache: Whether to reset the cache before fetching
    ///   - useToken: Whether to use authentication token if available
    /// - Returns: The parsed OPDS feed
    /// - Throws: PalaceError if fetch or parsing fails
    func fetchFeed(
        from url: URL,
        resetCache: Bool = false,
        useToken: Bool = true
    ) async throws -> TPPOPDSFeed {
        // Check for existing inflight request
        if let existingTask = inflightRequests[url] {
            return try await existingTask.value
        }

        // Create new task
        let task = Task<TPPOPDSFeed, Error> {
            return try await withCheckedThrowingContinuation { continuation in
                TPPOPDSFeed.withURL(
                    url,
                    shouldResetCache: resetCache,
                    useTokenIfAvailable: useToken
                ) { feed, errorDict in
                    if let feed = feed {
                        continuation.resume(returning: feed)
                    } else if let errorDict = errorDict as? [AnyHashable: Any] {
                        // Try to extract problem document for user-friendly error messages
                        let problemDoc = Self.problemDocumentFromDictionary(errorDict)
                        let error = self.parseError(from: errorDict, url: url)

                        // Attach problem document to error for better messaging
                        if let problemDoc = problemDoc {
                            let nsError = error as NSError
                            let errorWithProblemDoc = NSError(
                                domain: nsError.domain,
                                code: nsError.code,
                                userInfo: (nsError.userInfo ?? [:]).merging([
                                    "problemDocument": problemDoc,
                                    "problemDocumentTitle": problemDoc.title ?? "",
                                    "problemDocumentDetail": problemDoc.detail ?? ""
                                ]) { $1 }
                            )
                            continuation.resume(throwing: errorWithProblemDoc)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        // swarm_f3b9b087 item #9 audit: this branch (feed == nil
                        // AND errorDict == nil) was originally treated as a contract
                        // violation. Test-env evidence (OPDSFeedServiceStateMachineTests
                        // .testFetchLoansFeed_blocksUntilLoaded_thenFetches) shows the
                        // Obj-C bridge legitimately reaches this state for genuine
                        // network failures, so it is NOT a contract violation — it's
                        // a normal error path. Log it for diagnostics, then throw the
                        // localized OPDS error. NO `assertionFailure` here (it would
                        // crash DEBUG test runs).
                        Log.error(#file, "[OPDS_FEED] both feed and errorDict were nil for url=\(url) — propagating as opdsFeedInvalid")
                        continuation.resume(throwing: PalaceError.parsing(.opdsFeedInvalid))
                    }
                }
            }
        }

        // Store task
        inflightRequests[url] = task

        // Wait for completion and cleanup
        defer {
            inflightRequests[url] = nil
        }

        return try await task.value
    }

    /// Fetches a single OPDS entry from the given URL
    /// - Parameters:
    ///   - url: The URL to fetch from
    ///   - resetCache: Whether to reset the cache before fetching
    ///   - useToken: Whether to use authentication token if available
    /// - Returns: The first entry from the feed
    /// - Throws: PalaceError if fetch fails or no entry is found
    func fetchEntry(
        from url: URL,
        resetCache: Bool = false,
        useToken: Bool = true
    ) async throws -> TPPOPDSEntry {
        let feed = try await fetchFeed(from: url, resetCache: resetCache, useToken: useToken)

        guard let entry = feed.entries.first as? TPPOPDSEntry else {
            throw PalaceError.parsing(.opdsFeedInvalid)
        }

        return entry
    }

    /// Fetches a book from the given URL
    /// - Parameters:
    ///   - url: The URL to fetch from
    ///   - resetCache: Whether to reset the cache before fetching
    ///   - useToken: Whether to use authentication token if available
    /// - Returns: A TPPBook parsed from the entry
    /// - Throws: PalaceError if fetch or parsing fails
    func fetchBook(
        from url: URL,
        resetCache: Bool = false,
        useToken: Bool = true
    ) async throws -> TPPBook {
        let entry = try await fetchEntry(from: url, resetCache: resetCache, useToken: useToken)

        guard let book = TPPBook(entry: entry) else {
            throw PalaceError.parsing(.opdsFeedInvalid)
        }

        return book
    }

    // MARK: - Borrow Operations

    /// Borrows a book by performing a PUT/GET to the acquisition URL
    /// - Parameters:
    ///   - book: The book to borrow
    ///   - attemptDownload: Whether to immediately attempt download after borrowing
    /// - Returns: The borrowed book with updated acquisition links
    /// - Throws: PalaceError if borrow fails
    func borrowBook(
        _ book: TPPBook,
        attemptDownload: Bool = false
    ) async throws -> TPPBook {
        guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
            throw PalaceError.bookRegistry(.invalidState)
        }

        let borrowedBook = try await fetchBook(
            from: acquisitionURL,
            resetCache: true,
            useToken: true
        )

        return borrowedBook
    }

    // MARK: - Error Parsing

    private func parseError(from errorDict: [AnyHashable: Any], url: URL) -> PalaceError {
        // Check for problem document
        if let problemDoc = Self.problemDocumentFromDictionary(errorDict) {
            return parseProblemDocument(problemDoc)
        }

        // Check for generic error info
        if let errorType = errorDict["type"] as? String {
            switch errorType {
            case TPPProblemDocument.TypeNoActiveLoan:
                return .bookRegistry(.bookNotFound)
            case TPPProblemDocument.TypeLoanAlreadyExists:
                return .bookRegistry(.alreadyBorrowed)
            case TPPProblemDocument.TypeInvalidCredentials:
                return .authentication(.invalidCredentials)
            case TPPProblemDocument.TypeCannotFulfillLoan:
                return .download(.cannotFulfill)
            case TPPProblemDocument.TypeCannotIssueLoan:
                return .bookRegistry(.invalidState)
            case TPPProblemDocument.TypeCannotRender:
                return .parsing(.contentNotSupported)
            default:
                break
            }
        }

        // Check for HTTP status codes
        if let status = errorDict["status"] as? Int {
            switch status {
            case 401:
                return .authentication(.tokenExpired)
            case 403:
                return .network(.forbidden)
            case 404:
                return .network(.notFound)
            case 429:
                return .network(.rateLimited)
            case 500...599:
                return .network(.serverError)
            default:
                break
            }
        }

        // Default to parsing error
        Log.error(#file, "Failed to fetch OPDS feed from \(url): \(errorDict)")
        return .parsing(.opdsFeedInvalid)
    }

    func parseProblemDocument(_ problemDoc: TPPProblemDocument) -> PalaceError {
        guard let type = problemDoc.type else {
            // Unknown problem document - use title/detail if available
            let message = problemDoc.title ?? problemDoc.detail ?? "Unknown server error"
            Log.warn(#file, "Problem document with no type: \(message)")
            return .network(.serverError)
        }

        // The explicit switch below only covers the librarysimplified.org namespace.
        // palaceproject.io serves auth state via /auth/recoverable/* and /auth/unrecoverable/*
        // namespaces — recognise them so callers see the recoverability signal instead
        // of a generic credentials/server error.
        if problemDoc.isRecoverableAuthError {
            Log.info(#file, "Recoverable auth problem document '\(type)' — credentials should be marked stale")
            return .authentication(.tokenExpired)
        }
        if problemDoc.isUnrecoverableAuthError {
            Log.info(#file, "Unrecoverable auth problem document '\(type)' — re-auth will not help")
            return .authentication(.invalidCredentials)
        }

        switch type {
        case TPPProblemDocument.TypeNoActiveLoan:
            return .bookRegistry(.bookNotFound)
        case TPPProblemDocument.TypeLoanAlreadyExists:
            return .bookRegistry(.alreadyBorrowed)
        case TPPProblemDocument.TypeInvalidCredentials:
            return .authentication(.invalidCredentials)
        case TPPProblemDocument.TypeCannotFulfillLoan:
            return .download(.cannotFulfill)
        case TPPProblemDocument.TypeCannotIssueLoan:
            return .bookRegistry(.invalidState)
        case TPPProblemDocument.TypeCannotRender:
            return .parsing(.contentNotSupported)
        case TPPProblemDocument.TypePatronLoanLimit,
             TPPProblemDocument.TypePatronHoldLimit:
            // Patron quota errors. NOT auth — re-signing in won't help. Surface as
            // an invalid-state book registry error so the caller shows the server's
            // title/detail rather than spuriously triggering a re-auth modal.
            return .bookRegistry(.invalidState)
        case TPPProblemDocument.TypeCredentialsSuspended:
            return .authentication(.invalidCredentials)
        default:
            // Unknown problem document type - log it for future support
            let message = problemDoc.title ?? problemDoc.detail ?? "Unknown error"
            Log.warn(#file, "⚠️ Unknown problem document type '\(type)': \(message)")

            // Determine appropriate error category based on HTTP status if available.
            // CAUTION: do NOT auto-classify 401/403 as `.authentication` here — many
            // non-auth problem docs (e.g. loan-limit-reached, hold-limit-reached)
            // arrive with status 403 and used to be misclassified as auth failures,
            // which flipped authState to `.credentialsStale` and triggered a
            // spurious re-auth modal on every borrow attempt. The dedicated cases
            // above (and `isRecoverableAuthError` / `isUnrecoverableAuthError` checks
            // earlier in this method) already cover auth — anything reaching this
            // default with 401/403 is an unrecognized server condition, not auth.
            if let status = problemDoc.status {
                switch status {
                case 401, 403:
                    return .network(.forbidden)
                case 404:
                    return .network(.notFound)
                case 429:
                    return .network(.rateLimited)
                case 500...599:
                    return .network(.serverError)
                default:
                    break
                }
            }

            // Default to server error (non-retryable) rather than parsing error
            return .network(.serverError)
        }
    }

    // MARK: - Request Cancellation

    /// Cancels any inflight requests for the given URL
    func cancelRequest(for url: URL) {
        inflightRequests[url]?.cancel()
        inflightRequests[url] = nil
    }

    /// Cancels all inflight requests
    func cancelAllRequests() {
        inflightRequests.values.forEach { $0.cancel() }
        inflightRequests.removeAll()
    }
}

// MARK: - Convenience Extensions

extension OPDSFeedService {
    /// Fetches the user's loans feed.
    ///
    /// Bucket A migration (swarm_81b5099e Network-OPDS): awaits the
    /// Account.LoadState readiness gate before reading `loansUrl`. This
    /// closes the F-016 → audiobook race class where a sync
    /// `currentAccount?.loansUrl` read could fire before
    /// `loadCatalogs` had populated `details`, returning nil and silently
    /// taking the no-loans path. The gate forces the read past terminal
    /// state (.detailsLoaded or .detailsFailed) — never past nil.
    ///
    /// Param widened from `AccountsManager` to
    /// `TPPCurrentLibraryAccountProvider` so tests can substitute a
    /// fixture provider without standing up the full AccountsManager
    /// (which boots a background loadCatalogs on init). Production call
    /// sites pass the same `AppContainer.production().accountsManager`
    /// instance via the default arg.
    ///
    /// Single-timeout policy: this method inherits the caller's timeout
    /// pipeline. No `withTimeout` is layered around `awaitReady()`.
    func fetchLoans(
        accountsManager: TPPCurrentLibraryAccountProvider = AppContainer.production().accountsManager
    ) async throws -> TPPOPDSFeed {
        guard let currentAccount = accountsManager.currentAccount else {
            throw PalaceError.authentication(.accountNotFound)
        }

        let details: AccountDetails
        do {
            details = try await currentAccount.awaitReady()
        } catch {
            Log.warn(#file, "fetchLoans: awaitReady failed for account \(currentAccount.uuid): \(error)")
            throw error
        }

        guard let loansURL = details.loansUrl else {
            throw PalaceError.authentication(.accountNotFound)
        }

        return try await fetchFeed(from: loansURL, resetCache: true, useToken: true)
    }

    /// Fetches the catalog root
    func fetchCatalogRoot(accountsManager: AccountsManager = AppContainer.production().accountsManager) async throws -> TPPOPDSFeed {
        guard let catalogURLString = accountsManager.currentAccount?.catalogUrl,
              let catalogURL = URL(string: catalogURLString) else {
            throw PalaceError.authentication(.accountNotFound)
        }

        return try await fetchFeed(from: catalogURL, resetCache: false, useToken: false)
    }
}

// MARK: - Problem Document Parsing Helper

extension OPDSFeedService {
    /// Parses a problem document from a dictionary (avoids Objective-C selector conflict)
    private static func problemDocumentFromDictionary(_ dict: [AnyHashable: Any]) -> TPPProblemDocument? {
        // Convert to [String: Any]
        var stringDict: [String: Any] = [:]
        for (key, value) in dict {
            if let stringKey = key as? String {
                stringDict[stringKey] = value
            }
        }

        // Try to create problem document
        guard let data = try? JSONSerialization.data(withJSONObject: stringDict),
              let problemDoc = try? JSONDecoder().decode(TPPProblemDocument.self, from: data) else {
            return nil
        }

        return problemDoc
    }
}
