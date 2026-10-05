//
//  TPPRequestExecuting.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/24/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation

let TPPDefaultRequestTimeout: TimeInterval = 30.0

/// The single laundering point for the async bridge below.
///
/// `NYPLResult` carries a `URLResponse?` and an existential
/// `TPPUserFriendlyError`, neither of which is `Sendable`, so a result cannot
/// cross a continuation boundary on its own. Confining that one unsafe claim to
/// this file is the whole point: it is what lets a migrated caller `await` a
/// request with no carrier and no hop of its own. The alternative is one of
/// these at every call site, which is the debt this surface exists to retire.
///
/// Safe because the box that carries it resumes exactly once and the value is
/// read on the awaiting actor, never concurrently.
private struct SendableResultCarrier: @unchecked Sendable {
    let result: NYPLResult<Data>
}

/// `Sendable` states what every conformer already guarantees rather than
/// imposing anything new: `TPPNetworkExecutor` is declared `@unchecked
/// Sendable`, and so is each test double. Saying it on the protocol is what
/// makes `execute` reachable from an isolated context — without it, awaiting a
/// request from a `@MainActor` caller means sending the executor across
/// isolation, which the compiler refuses. That refusal is why callers were
/// stuck on the completion forms that cannot express isolation at all.
protocol TPPRequestExecuting: Sendable {
    /// Execute a given request.
    /// - Parameters:
    ///   - req: The request to perform.
    ///   - completion: Always called when the resource is either fetched from
    /// the network or from the cache.
    /// - Returns: The task issueing the given request.
    @discardableResult
    func executeRequest(_ req: URLRequest,
                        enableTokenRefresh: Bool,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask?

    /// Dispatch a request that was built for a SPECIFIC library rather than the
    /// currently selected one.
    ///
    /// PP-4986: the retry queue rebuilds a 401'd request using the account
    /// stamped on its task, and the default `executeRequest` stamps
    /// `currentAccountId` — because that is what it resolves. Callers that build
    /// for another library (Settings sign-in/sign-out via
    /// `TPPSignInBusinessLogic`, `NotificationService.deleteToken(for:)` — see the note below —) must
    /// say so here, or a retry authenticates as the wrong library.
    ///
    /// Additive rather than a signature change: conformers and mocks that do not
    /// implement it inherit the default below, which delegates and behaves
    /// exactly as before.
    @discardableResult
    func executeRequest(_ req: URLRequest,
                        enableTokenRefresh: Bool,
                        accountId: String?,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask?

    /// Execute a request and return its result, rather than handing it to a
    /// callback. Prefer this over the two completion forms above.
    ///
    /// A completion parameter typed `(NYPLResult<Data>) -> Void` cannot say where
    /// it runs. The executor builds its sessions with `delegateQueue: nil`, so
    /// every completion arrives on a background queue — while a closure formed in
    /// a `@MainActor` context inherits that isolation and type-checks anyway.
    /// That mismatch is the PP-5299 crash class, and at a completion call site
    /// the only remedies are a hop the author has to remember or an
    /// `@unchecked Sendable` carrier to launder the closure across.
    ///
    /// `await` needs neither. A continuation resumes on the awaiting caller's
    /// actor, so a `@MainActor` caller is returned to the main actor by the
    /// language rather than by discipline. The hazard is unrepresentable at an
    /// `await`, not merely avoided.
    ///
    /// Returns `NYPLResult` rather than throwing because the failure case
    /// carries the `URLResponse`, and sign-in reads problem documents off error
    /// responses. A throwing form would have to discard it.
    func execute(_ req: URLRequest,
                 enableTokenRefresh: Bool,
                 accountId: String?) async -> NYPLResult<Data>

    var requestTimeout: TimeInterval {get}

    static var defaultRequestTimeout: TimeInterval {get}
}

extension TPPRequestExecuting {
    /// Default: ignore the account and behave exactly as the two-argument form.
    /// A conformer that cannot honour per-request accounts is no worse than it
    /// was; only `TPPNetworkExecutor` overrides this.
    @discardableResult
    func executeRequest(_ req: URLRequest,
                        enableTokenRefresh: Bool,
                        accountId: String?,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
        executeRequest(req, enableTokenRefresh: enableTokenRefresh, completion: completion)
    }

    /// Bridges the callback form so every conformer — including the test
    /// doubles — gets the safe surface without implementing it. Additive, in the
    /// same spirit as the `accountId` overload above. `TPPNetworkExecutor` may
    /// override it later to go straight at its own async path.
    func execute(_ req: URLRequest,
                 enableTokenRefresh: Bool = true,
                 accountId: String? = nil) async -> NYPLResult<Data> {
        let box = CancellableContinuationBox<SendableResultCarrier>()
        // The box is the executor's own resume-exactly-once guard, reused here
        // rather than duplicated. It also makes the await cancellable: a
        // cancelled Task settles the box instead of suspending forever.
        let bridged: SendableResultCarrier? = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                executeRequest(req,
                               enableTokenRefresh: enableTokenRefresh,
                               accountId: accountId) { result in
                    box.finish(.success(SendableResultCarrier(result: result)))
                }
            }
        } onCancel: {
            box.cancel()
        }
        // `nil` only when the box resumed with an error, which it does solely on
        // cancellation — the request's own failures arrive inside NYPLResult.
        // Reported as NSURLErrorCancelled rather than Swift's CancellationError
        // so callers' existing network error handling applies unchanged.
        return bridged?.result ?? .failure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), nil)
    }

    var requestTimeout: TimeInterval {
        return Self.defaultRequestTimeout
    }

    static var defaultRequestTimeout: TimeInterval {
        return TPPDefaultRequestTimeout
    }

    @discardableResult
    func executeRequest(_ req: URLRequest,
                        useTokenIfAvailable: Bool = true,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask {
        URLSessionDataTask()
    }
}

// MARK: - TokenRefreshing seam (§10.2)
//
// `TPPSignInBusinessLogic.getBearerToken` historically accepted a concrete
// `TPPNetworkExecutor`. The `TokenRefreshing` protocol abstracts the single
// method it actually invokes (`executeTokenRefresh`) so that pure
// in-memory unit-test mocks can stand in for the real executor without
// having to spin up a `URLSessionConfiguration` + `HTTPStubURLProtocol`
// stack. Production callers still pass a real `TPPNetworkExecutor` (which
// gains conformance for free via an empty extension).
import PalaceAuth

protocol TokenRefreshing: AnyObject {
    /// Perform a bearer-token refresh against the supplied `tokenURL` using
    /// username/password basic-auth credentials. On success, the
    /// `TokenResponse` is reported to `completion`; on failure the underlying
    /// error is forwarded.
    func executeTokenRefresh(username: String,
                             password: String,
                             tokenURL: URL,
                             accountId: String?,
                             completion: @escaping (Result<TokenResponse, Error>) -> Void)
}
