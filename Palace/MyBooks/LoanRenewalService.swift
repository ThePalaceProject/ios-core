//
//  LoanRenewalService.swift
//  Palace
//
//  In-app loan renewal: POSTs the book's OPDS renew URL and refreshes the
//  registry on success.
//
//  Auth errors are host-scoped: the decision goes through an
//  `AuthErrorClassifier` bound to the current account's auth-surface hosts,
//  so only a 401 from one of those hosts marks credentials stale. A 401 from
//  any other host must never cause a blanket logout.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAuth
import PalaceCatalog
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - RenewalPosting

/// Narrow POST seam. Production adapter wraps `TPPNetworkExecutor.POST`;
/// tests inject a stub returning a controlled `HTTPURLResponse`.
protocol RenewalPosting: Sendable {
    /// POST to `url`. Returns the raw body and the HTTP response. A `nil`
    /// response means the transport failed before any HTTP landed.
    func post(to url: URL) async -> (data: Data?, response: HTTPURLResponse?)
}

// MARK: - LoanRenewalService

final class LoanRenewalService: @unchecked Sendable {

    /// The outcome of a renewal attempt.
    enum RenewOutcome: Equatable {
        /// The server extended the loan (2xx). Registry refreshed.
        case success
        /// A 401 from an account-surface host — credentials marked stale;
        /// the caller should re-prompt sign-in.
        case reauthRequired
        /// A 401 from a host OUTSIDE the current account's auth surface —
        /// ignored, credentials not marked stale.
        case foreignHost401
        /// The book exposes no renew (borrow-rel) URL.
        case noRenewURL
        /// The transport failed (offline / no response).
        case networkError
        /// Any other non-2xx server response.
        case failed(status: Int)
    }

    private let poster: RenewalPosting
    private let classifier: AuthErrorClassifier
    private let bookRegistry: TPPBookRegistryProvider
    /// Invoked only when a 401 comes from an account-surface host.
    private let markCredentialsStale: @Sendable () -> Void

    /// Designated init. `classifier` is REQUIRED and must be host-scoped
    /// (built with a non-nil `currentAccountHostsProvider`) — use
    /// `LoanRenewalService.production(...)` in app code, which guarantees
    /// this. A bare `AuthErrorClassifier()` here would disable host scoping.
    init(
        poster: RenewalPosting,
        classifier: AuthErrorClassifier,
        bookRegistry: TPPBookRegistryProvider,
        markCredentialsStale: @escaping @Sendable () -> Void
    ) {
        self.poster = poster
        self.classifier = classifier
        self.bookRegistry = bookRegistry
        self.markCredentialsStale = markCredentialsStale
    }

    // MARK: - Renew-URL extraction (pure)

    /// The OPDS renew endpoint for a book. In the Palace circulation
    /// model an active loan is renewed by re-POSTing its borrow-rel
    /// acquisition link, so the renew URL is the borrow acquisition's
    /// `hrefURL`. Pure — no I/O; unit-testable over a fixture book.
    static func renewURL(for book: TPPBook) -> URL? {
        book.acquisitions.first { $0.relation == .borrow }?.hrefURL
    }

    // MARK: - Renew

    /// Attempt to renew `book`'s loan. Returns the typed outcome; on
    /// `.success` the registry is refreshed from the server so the
    /// extended `until` propagates to My Books.
    @discardableResult
    func renew(book: TPPBook) async -> RenewOutcome {
        guard let url = Self.renewURL(for: book) else {
            Log.info(#file, "Renew requested for '\(book.title)' but no renew URL is available")
            return .noRenewURL
        }

        let (data, response) = await poster.post(to: url)

        guard let response else {
            return .networkError
        }

        let status = response.statusCode

        // Loan extended: a loans-feed sync brings the new expiry into My Books.
        if (200...299).contains(status) {
            bookRegistry.sync(completion: nil)
            return .success
        }

        // Host-scoped classification, so a foreign-host 401 never logs out.
        let problemDoc = data.flatMap { TPPProblemDocument.fromProblemResponseData($0) }
        let outcome = classifier.classify(
            response: response,
            problemDocument: problemDoc,
            body: data,
            originalRequestURL: url
        )

        switch outcome {
        case .ok:
            // Foreign-host 401: not this account's session.
            Log.info(#file, "Renew got a non-account-host response; ignoring per host scoping")
            return .foreignHost401
        case .reauthRequired:
            Log.info(#file, "Renew hit an account-host auth error; marking credentials stale")
            markCredentialsStale()
            return .reauthRequired
        default:
            return .failed(status: status)
        }
    }
}

// MARK: - Production factory

extension LoanRenewalService {
    /// The way to build a production `LoanRenewalService`. Binds the
    /// classifier to the active account's auth-surface hosts, like
    /// `TPPNetworkResponder` and the borrow/return sites. A bare
    /// `AuthErrorClassifier()` defaults its provider to `{ nil }`, which
    /// disables Rule 4b and reopens the cross-host logout (PR #1018).
    ///
    /// `poster` and `hostsProvider` are injectable for tests.
    static func production(
        executor: TPPNetworkExecutor,
        bookRegistry: TPPBookRegistryProvider,
        poster: RenewalPosting? = nil,
        hostsProvider: (@Sendable () -> Set<String>?)? = nil
    ) -> LoanRenewalService {
        let hosts: @Sendable () -> Set<String>? = hostsProvider ?? {
            AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts
        }
        let classifier = AuthErrorClassifier(currentAccountHostsProvider: hosts)
        return LoanRenewalService(
            poster: poster ?? NetworkExecutorRenewalPoster(executor: executor),
            classifier: classifier,
            bookRegistry: bookRegistry,
            markCredentialsStale: {
                AppContainer.production().accountsManager.currentUserAccount.markCredentialsStale()
            })
    }
}

// MARK: - Production POST adapter

/// `RenewalPosting` backed by `TPPNetworkExecutor.POST`.
final class NetworkExecutorRenewalPoster: RenewalPosting, @unchecked Sendable {
    private let executor: TPPNetworkExecutor

    init(executor: TPPNetworkExecutor) {
        self.executor = executor
    }

    func post(to url: URL) async -> (data: Data?, response: HTTPURLResponse?) {
        await withCheckedContinuation { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = executor.POST(request, useTokenIfAvailable: true) { data, response, _ in
                continuation.resume(returning: (data, response as? HTTPURLResponse))
            }
        }
    }
}
