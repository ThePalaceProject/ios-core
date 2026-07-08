//
//  LoanRenewalService.swift
//  Palace
//
//  Reliability WS-C — in-app loan renewal. Extracts the OPDS renew URL
//  from a book, POSTs it, and refreshes the registry loan on success.
//
//  INV-5 (auth-error host scoping): the 401/credentials-stale decision
//  is routed through `AuthErrorClassifier` constructed with the current
//  account's `currentAccountHostsProvider`. A 401 from a host OUTSIDE the
//  current account's auth surface classifies as `.ok` and MUST NOT mark
//  the current account's credentials stale (never a blanket logout). Only
//  a 401 from an account-surface host marks credentials stale.
//
//  The network POST is behind the narrow `RenewalPosting` protocol so the
//  service is unit-testable without a live URLSession; production wires a
//  `TPPNetworkExecutor`-backed adapter.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAuth
import PalaceCatalog
import PalaceLogging

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
        /// ignored per INV-5, credentials NOT marked stale.
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
    /// Side-effect gate invoked ONLY when a 401 is scoped to an
    /// account-surface host. Injected so tests can assert it is NOT
    /// called on a foreign-host 401 (INV-5).
    private let markCredentialsStale: @Sendable () -> Void

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

        // 2xx — the loan was extended. Refresh the registry from the
        // server so the new expiry lands in My Books. (A full loans-feed
        // sync is used rather than hand-parsing the entry — it reaches the
        // same end via existing public registry API.)
        if (200...299).contains(status) {
            bookRegistry.sync(completion: nil)
            return .success
        }

        // Non-2xx — route the auth decision through the host-scoped
        // classifier so a foreign-host 401 never blanket-logs-out (INV-5).
        let problemDoc = data.flatMap { TPPProblemDocument.fromProblemResponseData($0) }
        let outcome = classifier.classify(
            response: response,
            problemDocument: problemDoc,
            body: data,
            originalRequestURL: url
        )

        switch outcome {
        case .ok:
            // Cross-domain / foreign-host 401: not our account's session.
            // Do NOT mark credentials stale.
            Log.info(#file, "Renew got a non-account-host response; ignoring per host scoping")
            return .foreignHost401
        case .reauthRequired:
            // 401 from an account-surface host — real session expiry.
            Log.info(#file, "Renew hit an account-host auth error; marking credentials stale")
            markCredentialsStale()
            return .reauthRequired
        default:
            return .failed(status: status)
        }
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
