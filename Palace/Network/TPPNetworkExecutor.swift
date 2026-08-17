//
//  TPPNetworkExecutor.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/19/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceNetwork
// `@preconcurrency`: PalaceAuth's `TokenResponse` (an `@objcMembers` class) is not
// Sendable-audited and crosses the `@Sendable` token-refresh Task in
// `refreshTokenAndResume` via the `Result<TokenResponse, Error>` continuation.
// Honest ceiling until PalaceAuth annotates `TokenResponse: Sendable`; recorded in
// RIPPLES.md as the preferred upstream fix.
@preconcurrency import PalaceAuth

enum NYPLResult<SuccessInfo> {
    case success(SuccessInfo, URLResponse?)
    case failure(TPPUserFriendlyError, URLResponse?)
}

/// Actor that serializes access to the token refresh state and retry queue.
private actor TokenRefreshCoordinator {
    var isRefreshing = false
    var retryQueue: [URLSessionTask] = []
    /// Count of underlying token-refresh attempts that actually took the
    /// single-flight slot (i.e. transitioned `isRefreshing` from false to true).
    /// Read-only; test-observable via `TPPNetworkExecutor.refreshAttemptCount`.
    private(set) var refreshAttemptCount: Int = 0

    /// Monotonic id of the current single-flight refresh, bumped each time the
    /// slot is claimed. Lets a watchdog scheduled for one refresh tell whether
    /// the slot it is policing is still the same one — vs. already completed
    /// and re-claimed by a newer refresh, which it must not disturb.
    private(set) var refreshGeneration: Int = 0

    func setRefreshing(_ value: Bool) {
        if value && !isRefreshing {
            refreshAttemptCount += 1
            refreshGeneration += 1
        }
        isRefreshing = value
    }

    /// Atomically attempts to claim the single-flight refresh slot.
    /// Returns `true` if the caller now owns the in-flight refresh, `false`
    /// if another caller already holds it. This collapses the previous
    /// check-then-act pattern into a single actor-hop so two concurrent
    /// 401s can never both proceed past the guard.
    func tryClaimRefreshSlot() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        refreshAttemptCount += 1
        refreshGeneration += 1
        return true
    }

    func currentGeneration() -> Int { refreshGeneration }

    /// Watchdog escape hatch. If the slot is STILL held by the same refresh
    /// generation — i.e. the refresh never completed and never called
    /// `setRefreshing(false)` — force-release it and return the stranded retry
    /// queue so the caller can fail those requests. Returns `nil` when the
    /// refresh already completed normally or a newer one is in progress, in
    /// which case the watchdog must not interfere.
    func forceReleaseIfStuck(generation: Int) -> [URLSessionTask]? {
        guard isRefreshing, refreshGeneration == generation else { return nil }
        isRefreshing = false
        let stranded = retryQueue
        retryQueue.removeAll()
        return stranded
    }

    func resetRefreshAttemptCount() {
        refreshAttemptCount = 0
    }

    func appendToRetryQueue(_ task: URLSessionTask) {
        retryQueue.append(task)
    }

    func drainRetryQueue() -> [URLSessionTask] {
        let tasks = retryQueue
        retryQueue.removeAll()
        return tasks
    }
}

/// Carries a non-`Sendable` completion closure across a `@Sendable` `Task`
/// boundary (the token-refresh continuations in `refreshTokenAndResume` and
/// `executeTokenRefresh`). Each boxed completion is invoked at most once, and the
/// producing method serializes its use, so `@unchecked Sendable` is sound. This is
/// the isolation-preserving alternative to marking the public completion parameters
/// `@Sendable`, which would ripple onto every caller. Mirrors `ImageCompletionBox`.
private final class CompletionBox<T>: @unchecked Sendable {
    let call: (T) -> Void
    init(_ call: @escaping (T) -> Void) { self.call = call }
}

/// Carries a non-`Sendable` token-refresh `Result` across the `@Sendable` `Task`
/// boundary inside `refreshTokenAndResume`. The `Result<TokenResponse, Error>`
/// value is produced on the refresh completion callback and consumed exactly once
/// inside the follow-up `Task`, so single-ownership handoff makes `@unchecked
/// Sendable` sound — the honest alternative to marking the completion `@Sendable`
/// (which would ripple onto the public `executeTokenRefresh` signature) or waiting
/// on `TokenResponse: Sendable` from PalaceAuth. Mirrors `CompletionBox`.
private final class CompletionResultBox: @unchecked Sendable {
    let result: Result<TokenResponse, Error>
    init(_ result: Result<TokenResponse, Error>) { self.result = result }
}

/// `@unchecked Sendable`: lets the executor satisfy the now-`Sendable`
/// `NetworkClient` boundary (`URLSessionNetworkClient` holds one) and be captured
/// across concurrency domains as it already is in production. The conformance is
/// honest, not a blanket silence — every stored property is immutable-after-init
/// or independently synchronized:
///   • `transport` / `responder` — `let`; both wrap the shared, thread-safe
///     `URLSession` and are shared-by-design (the app routes through one executor).
///   • `tokenCoordinator` — a `private actor` (its `isRefreshing`/`retryQueue`
///     state is actor-isolated).
///   • `_accountsManager` — `var`, but assigned ONLY in the DI initializers
///     (never mutated after construction; nil otherwise → lazy production read).
///   • `tokenRefreshWatchdogSeconds` — `var` with ZERO mutation sites repo-wide;
///     effectively constant after init.
/// NOT `final`: three PalaceTests mocks subclass this for stubbing
/// (SpyAudiobookNetworkExecutor, MockNetworkExecutorForSync, RecordingExecutorMock).
/// They add only test-only or lock-guarded state, so they don't defeat the
/// assertion; `final` would break the test-target build.
@objc class TPPNetworkExecutor: NSObject, @unchecked Sendable {
    let transport: NetworkTransport
    private let tokenCoordinator = TokenRefreshCoordinator()

    /// Ceiling on a single token refresh before the watchdog force-releases a
    /// wedged slot. Set comfortably above the shared session's resource
    /// timeout (60s) so it only ever fires on a genuine wedge, never on a
    /// slow-but-progressing refresh. Overridable so tests can drive it fast.
    static let defaultTokenRefreshWatchdogSeconds: TimeInterval = 75
    var tokenRefreshWatchdogSeconds: TimeInterval = TPPNetworkExecutor.defaultTokenRefreshWatchdogSeconds

    // `internal` (default) rather than `private` so adversarial tests can
    // wire a completion onto a synthetic task before invoking
    // `refreshTokenAndResume(task:)`. The responder is otherwise only ever
    // touched by the executor itself; production callers must keep going
    // through the executor's higher-level GET / PUT / POST / DELETE surface.
    let responder: TPPNetworkResponder
    private var _accountsManager: TPPLibraryAccountsProvider?
    private var accountsManager: TPPLibraryAccountsProvider {
        _accountsManager ?? AppContainer.production().accountsManager
    }

    @objc init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
               cachingStrategy: NYPLCachingStrategy,
               delegateQueue: OperationQueue? = nil) {
        self.responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                             useFallbackCaching: cachingStrategy == .fallback)
        self.transport = NetworkTransport(delegate: self.responder,
                                          cachingStrategy: cachingStrategy,
                                          requestTimeout: TPPNetworkExecutor.defaultRequestTimeout,
                                          delegateQueue: delegateQueue)
        // accountsManager is lazy — accessed on first use, not during init
        // This avoids circular singleton deadlock: TPPNetworkExecutor ↔ AccountsManager
        super.init()
    }

    /// Test-friendly initializer allowing a custom URLSessionConfiguration (e.g., with custom URLProtocol classes)
    @objc init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
               cachingStrategy: NYPLCachingStrategy,
               sessionConfiguration: URLSessionConfiguration,
               delegateQueue: OperationQueue? = nil) {
        self.responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                             useFallbackCaching: cachingStrategy == .fallback)
        self.transport = NetworkTransport(delegate: self.responder,
                                          sessionConfiguration: sessionConfiguration,
                                          delegateQueue: delegateQueue,
                                          cachingStrategy: cachingStrategy,
                                          requestTimeout: TPPNetworkExecutor.defaultRequestTimeout)
        // accountsManager is lazy — avoids circular init deadlock
        super.init()
    }

    /// DI-friendly initializer for testing
    init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
         cachingStrategy: NYPLCachingStrategy,
         accountsManager: TPPLibraryAccountsProvider = AppContainer.production().accountsManager,
         delegateQueue: OperationQueue? = nil) {
        self.responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                             useFallbackCaching: cachingStrategy == .fallback)
        self.transport = NetworkTransport(delegate: self.responder,
                                          cachingStrategy: cachingStrategy,
                                          requestTimeout: TPPNetworkExecutor.defaultRequestTimeout,
                                          delegateQueue: delegateQueue)
        self._accountsManager = accountsManager
        super.init()
    }

    /// Full-DI initializer used by adversarial tests that need BOTH a custom
    /// `URLSessionConfiguration` (for `URLProtocol`-based stubbing) and an
    /// injected `TPPLibraryAccountsProvider` (so the executor's per-account
    /// credential reads target a test-controlled mock instead of
    /// `AppContainer.production().accountsManager`). No production caller
    /// needs both seams at once; this exists for token-refresh / retry-queue
    /// coverage where the executor's token-refresh code path reads from
    /// `self.accountsManager` and writes via `setAuthToken` on the resolved
    /// `TPPUserAccount`. See `TokenRefreshAndRetryQueueTests` for the
    /// motivating scenarios.
    init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
         cachingStrategy: NYPLCachingStrategy,
         sessionConfiguration: URLSessionConfiguration,
         accountsManager: TPPLibraryAccountsProvider,
         delegateQueue: OperationQueue? = nil) {
        self.responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                             useFallbackCaching: cachingStrategy == .fallback)
        self.transport = NetworkTransport(delegate: self.responder,
                                          sessionConfiguration: sessionConfiguration,
                                          delegateQueue: delegateQueue,
                                          cachingStrategy: cachingStrategy,
                                          requestTimeout: TPPNetworkExecutor.defaultRequestTimeout)
        self._accountsManager = accountsManager
        super.init()
    }

    #if DEBUG
    /// Recreate the underlying URLSession so it picks up any newly-registered
    /// URLProtocol classes (e.g. MockBackendURLProtocol). Delegates to the
    /// transport.
    func recreateSession() {
        transport.recreateSession()
        Log.info(#file, "TPPNetworkExecutor: session recreated for mock backend")
    }
    #endif

    /// Number of underlying token-refresh attempts that have taken the
    /// single-flight slot since process start (or last reset). Concurrent
    /// 401s that coalesce behind an in-flight refresh do NOT increment this.
    /// Exposed for adversarial tests; safe to read from any context.
    var refreshAttemptCount: Int {
        get async { await tokenCoordinator.refreshAttemptCount }
    }

    /// Test-only: resets the refresh-attempt counter to zero. Does not affect
    /// in-flight refresh state.
    func resetRefreshAttemptCount() async {
        await tokenCoordinator.resetRefreshAttemptCount()
    }

    /// Self-healing guard against a wedged token refresh.
    ///
    /// If a refresh ever fails to call `setRefreshing(false)` (e.g. its
    /// completion never fires, or `self` deallocates before the completion
    /// runs), `isRefreshing` would stay `true` forever — and because every
    /// later token-authed request coalesces behind the in-flight refresh, they
    /// would all queue and hang until the app is force-quit. That matches the
    /// "main catalog hangs across library switches until restart" report.
    ///
    /// This fires `tokenRefreshWatchdogSeconds` after the slot is claimed and,
    /// if the SAME refresh generation still holds it, force-releases the slot
    /// and fails the stranded queue so the system recovers on its own.
    private func scheduleTokenRefreshWatchdog(generation: Int) {
        let timeout = tokenRefreshWatchdogSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self else { return }
            guard let stranded = await self.tokenCoordinator.forceReleaseIfStuck(generation: generation) else {
                return // refresh completed normally, or a newer one took over
            }
            Log.error(#file, "Token refresh watchdog fired after \(timeout)s — force-releasing wedged refresh (generation \(generation)); failing \(stranded.count) stranded request(s)")
            stranded.forEach { $0.cancel() }
        }
    }

    /// Test windows into the token-refresh coordinator so the watchdog
    /// contract can be locked deterministically, without real timing. Plain
    /// `internal` (matching the existing `refreshAttemptCount` accessor
    /// convention) rather than a `#if DEBUG` block the blast-radius gate flags.
    var isTokenRefreshingForTesting: Bool {
        get async { await tokenCoordinator.isRefreshing }
    }
    func claimTokenRefreshSlotForTesting() async -> Bool {
        await tokenCoordinator.tryClaimRefreshSlot()
    }
    func currentTokenRefreshGenerationForTesting() async -> Int {
        await tokenCoordinator.currentGeneration()
    }
    func appendTokenRetryForTesting(_ task: URLSessionTask) async {
        await tokenCoordinator.appendToRetryQueue(task)
    }
    func setTokenRefreshingForTesting(_ value: Bool) async {
        await tokenCoordinator.setRefreshing(value)
    }
    func forceReleaseStuckTokenRefreshForTesting(generation: Int) async -> [URLSessionTask]? {
        await tokenCoordinator.forceReleaseIfStuck(generation: generation)
    }

    func GET(_ reqURL: URL,
             useTokenIfAvailable: Bool = true,
             completion: @escaping (_ result: NYPLResult<Data>) -> Void) {
        let req = request(for: reqURL, useTokenIfAvailable: useTokenIfAvailable)
        _ = executeRequest(req, enableTokenRefresh: useTokenIfAvailable, completion: completion)
    }

    @objc func pauseAllTasks() {
        transport.pauseAllTasks()
    }

    @objc func resumeAllTasks() {
        transport.resumeAllTasks()
    }

    /// Cancels all active tasks that are not related to audiobook streaming.
    /// Called during account switches to prevent requests from completing with
    /// the wrong account's credentials. Synchronous on purpose — see
    /// `ActiveTasksStore` doc-comment.
    @objc func cancelNonEssentialTasks() {
        transport.cancelNonEssentialTasks()
    }

    /// Number of in-flight tasks the transport currently holds — i.e. tasks
    /// in `.running` or `.suspended` URLSessionTask state. Read-only
    /// observation surface for tests that need to verify
    /// `cancelNonEssentialTasks` actually drops the live count. Production
    /// callers must not use this for control flow; the transport's task
    /// registry is the source of truth.
    var liveTaskCount: Int {
        transport.activeTasksStore.liveTaskCount
    }
}

// `executeTokenRefresh(username:password:tokenURL:accountId:completion:)`
// is defined further down on `TPPNetworkExecutor` (no `accountId` default
// parameter is needed for protocol witness selection at the test seam
// callers — see §10.2 of `docs/Testing/Test_Seams_Refactor_Plan.md`).
extension TPPNetworkExecutor: TokenRefreshing { }

extension TPPNetworkExecutor: TPPRequestExecuting {
    @discardableResult
    func executeRequest(_ req: URLRequest, enableTokenRefresh: Bool, completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
        let accountId = accountsManager.currentAccountId
        let userAccount = accountId.flatMap { accountsManager.userAccount(for: $0) } ?? accountsManager.currentUserAccount

        // SAML auth uses cookies, not tokens - proceed directly
        if let authDefinition = userAccount.authDefinition, authDefinition.isSaml {
            return performDataTask(with: req, completion: completion)
        }

        // Proactive token refresh: if token will expire soon, refresh before the request
        if enableTokenRefresh,
           userAccount.authTokenNearExpiry,
           let authDef = userAccount.authDefinition,
           authDef.isToken || authDef.isOauth,
           authDef.tokenURL != nil {
            Log.info(#file, "Token near expiry - proactively refreshing before request")
            refreshTokenAndResume(task: nil, accountId: accountId) { [weak self] _ in
                _ = self?.performDataTask(with: req, completion: completion)
            }
            return nil
        }

        return performDataTask(with: req, completion: completion)
    }

    private func performDataTask(with request: URLRequest,
                                 completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask {
        let task = transport.urlSession.dataTask(with: request)
        responder.addCompletion(completion, taskID: task.taskIdentifier)
        transport.activeTasksStore.add(task)
        task.resume()
        return task
    }
}

extension TPPNetworkExecutor {
    private func createErrorForRetryFailure() -> NSError {
        return NSError(
            domain: TPPErrorLogger.clientDomain,
            code: TPPErrorCode.invalidCredentials.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Unauthorized HTTP after token refresh attempt"]
        )
    }
}

extension TPPNetworkExecutor {
    @objc func request(for url: URL, useTokenIfAvailable: Bool = true) -> URLRequest {
        return request(for: url, useTokenIfAvailable: useTokenIfAvailable, accountId: nil)
    }

    func request(for url: URL, useTokenIfAvailable: Bool = true, accountId: String?) -> URLRequest {
        var urlRequest = URLRequest(url: url,
                                    cachePolicy: transport.requestCachePolicy)
        // Don't optimistically try HTTP/3 (QUIC) on first contact with each host.
        // Some library servers advertise h3 but have broken QUIC — iOS retries
        // twice (~260ms wasted) before falling back to h2. With this flag off,
        // first requests use h2; the session upgrades to h3 automatically on
        // subsequent requests if the server confirms working QUIC via Alt-Svc.
        urlRequest.assumesHTTP3Capable = false
        urlRequest.applyCustomUserAgent()
        // Use per-account instance to prevent TOCTOU races during account switches.
        // Without this, another thread could change libraryUUID between
        // sharedAccount() and the property reads, causing cross-account
        // credential leaks.
        let resolvedId = accountId ?? accountsManager.currentAccountId ?? ""
        let snapshot = accountsManager.userAccount(for: resolvedId).credentialSnapshot()

        // SAML auth uses cookies, not tokens — make sure they are installed in
        // the shared cookie storage before the request goes out. Removing this
        // block silently regresses SAML sign-in.
        if let authDef = snapshot.authDefinition, authDef.isSaml,
           let cookies = snapshot.cookies, !cookies.isEmpty {
            let shared = HTTPCookieStorage.shared
            for cookie in cookies { shared.setCookie(cookie) }
        }

        if let authToken = snapshot.authToken, useTokenIfAvailable {
            urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("", forHTTPHeaderField: "Accept-Language")
        return urlRequest
    }

    @objc func clearCache() {
        transport.clearCache()
    }
}

extension TPPNetworkExecutor {
    /// Legacy class-func bearer-auth applier. Resolves credentials through
    /// `AppContainer.production().accountsManager.currentUserAccount` — which
    /// re-reads the "current" account on every call. During a library swap
    /// mid-download that resolution can transiently point at the wrong
    /// account (the swap window), producing the spurious-login-modal class
    /// of bugs.
    ///
    /// **Prefer the instance overload `bearerAuthorized(request:accountId:)`
    /// for any new call site.** It uses the executor's injected
    /// `accountsManager` and an explicit captured `accountId`, deterministically
    /// closing the swap window.
    ///
    /// This static remains for legacy Objective-C / non-injected call sites
    /// where threading a captured accountId would require lifting a lot of
    /// upstream code. It is the **only** place in the file that resolves
    /// `currentUserAccount` — that invariant is asserted by
    /// `MyBooksDownloadCenterAccountIdThreadingTests`.
    @objc class func bearerAuthorized(request: URLRequest) -> URLRequest {
        var request = request
        let snapshot = AppContainer.production().accountsManager.currentUserAccount.credentialSnapshot()

        if let authToken = snapshot.authToken, !authToken.isEmpty {
            let tokenPrefix = String(authToken.prefix(8))
            Log.debug(#file, "Adding Bearer token (prefix: \(tokenPrefix)...) to request for \(request.url?.host ?? "unknown")")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        } else {
            Log.warn(#file, "No auth token available for request to \(request.url?.host ?? "unknown") - hasCredentials: \(snapshot.hasCredentials)")
            request.setValue("", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Apply the bearer token for an explicit `accountId`, eliminating the
    /// transient `currentUserAccount` re-resolution window observed during
    /// library swaps mid-download. The resolved snapshot is taken against
    /// the executor's injected `accountsManager`, never through
    /// `AppContainer.production()` — that singleton read is reserved for
    /// the legacy no-arg overload above (the migration tail).
    ///
    /// Pass `nil` to fall back to the resolver — same behavior as the legacy
    /// `bearerAuthorized(request:)` class func, but routed through the
    /// instance so tests can substitute an injected `accountsManager`. Pass
    /// a real UUID captured at download START to pin credentials to the
    /// originally-selected account; downstream library swaps cannot affect
    /// the resulting Authorization header.
    @objc func bearerAuthorized(request: URLRequest, accountId: String?) -> URLRequest {
        var request = request
        // When `accountId` is non-nil, resolve directly against the
        // injected accountsManager. When nil, fall back to `currentAccountId`
        // — the legacy resolver path, but contained to this single instance
        // method so test executors can supply a fixed accountsManager.
        let resolvedId = accountId ?? accountsManager.currentAccountId ?? ""
        let snapshot = accountsManager.userAccount(for: resolvedId).credentialSnapshot()

        if let authToken = snapshot.authToken, !authToken.isEmpty {
            let tokenPrefix = String(authToken.prefix(8))
            Log.debug(#file, "Adding Bearer token (prefix: \(tokenPrefix)...) to request for \(request.url?.host ?? "unknown") (accountId: \(accountId ?? "<resolver-fallback>"))")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        } else {
            Log.warn(#file, "No auth token available for request to \(request.url?.host ?? "unknown") - hasCredentials: \(snapshot.hasCredentials), accountId: \(accountId ?? "<resolver-fallback>")")
            request.setValue("", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    @objc func download(_ reqURL: URL,
                        completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDownloadTask {
        let req = request(for: reqURL)
        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }

        let task = transport.urlSession.downloadTask(with: req)
        responder.addCompletion(completionWrapper, taskID: task.taskIdentifier)
        task.resume()

        return task
    }

    @objc func addBearerAndExecute(_ request: URLRequest,
                                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        let req = TPPNetworkExecutor.bearerAuthorized(request: request)
        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }
        return executeRequest(req, enableTokenRefresh: false, completion: completionWrapper)
    }

    @objc func GET(_ reqURL: URL,
                   cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy,
                   useTokenIfAvailable: Bool = true,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        GET(request: request(for: reqURL), cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
    }

    @objc func GET(request: URLRequest,
                   cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy,
                   useTokenIfAvailable: Bool,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        if request.httpMethod != "GET" {
            var newRequest = request
            newRequest.httpMethod = "GET"
            return GET(request: newRequest, cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        var updatedReq = request
        updatedReq.cachePolicy = cachePolicy

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }
        return executeRequest(updatedReq, enableTokenRefresh: useTokenIfAvailable, completion: completionWrapper)
    }

    @objc func PUT(_ reqURL: URL,
                   useTokenIfAvailable: Bool,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        PUT(request: request(for: reqURL), useTokenIfAvailable: useTokenIfAvailable, completion: completion)
    }

    @objc func PUT(request: URLRequest,
                   useTokenIfAvailable: Bool,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        if request.httpMethod != "PUT" {
            var newRequest = request
            newRequest.httpMethod = "PUT"
            return PUT(request: newRequest, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }
        return executeRequest(request, enableTokenRefresh: useTokenIfAvailable, completion: completionWrapper)
    }

    @discardableResult
    @objc
    func POST(_ request: URLRequest,
              useTokenIfAvailable: Bool,
              completion: ((_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void)?) -> URLSessionDataTask? {
        if request.httpMethod != "POST" {
            var newRequest = request
            newRequest.httpMethod = "POST"
            return POST(newRequest, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion?(data, response, nil)
            case let .failure(error, response): completion?(nil, response, error)
            }
        }
        return executeRequest(request, enableTokenRefresh: useTokenIfAvailable, completion: completionWrapper)
    }

    @discardableResult
    @objc
    func DELETE(_ request: URLRequest,
                useTokenIfAvailable: Bool,
                completion: ((_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void)?) -> URLSessionDataTask? {
        if request.httpMethod != "DELETE" {
            var newRequest = request
            newRequest.httpMethod = "DELETE"
            return DELETE(newRequest, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion?(data, response, nil)
            case let .failure(error, response): completion?(nil, response, error)
            }
        }
        return executeRequest(request, enableTokenRefresh: false, completion: completionWrapper)
    }

    func refreshTokenAndResume(task: URLSessionTask?, accountId: String? = nil, completion: ((_ result: NYPLResult<Data>) -> Void)? = nil) {
        let capturedAccountId = accountId ?? accountsManager.currentAccountId
        // Box the non-`Sendable` completion so it can cross the `@Sendable` Task
        // boundaries below (this Task and the nested token-refresh continuation)
        // without rippling `@Sendable` onto the public signature.
        let completionBox = completion.map { CompletionBox($0) }
        Task { [weak self] in
            guard let self = self else {
                let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Network executor deallocated"])
                completionBox?.call(NYPLResult.failure(error, nil))
                return
            }

            // Atomic check-and-claim: only one caller can take the refresh slot.
            let claimed = await self.tokenCoordinator.tryClaimRefreshSlot()

            if !claimed {
                Log.debug(#file, "Token refresh already in progress, queueing task for retry")
                if let task {
                    await self.tokenCoordinator.appendToRetryQueue(task)
                    if let completionBox {
                        self.responder.addCompletion(completionBox.call, taskID: task.taskIdentifier)
                    }
                } else {
                    let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Token refresh in progress"])
                    completionBox?.call(NYPLResult.failure(error, nil))
                }
                return
            }

            // Arm the self-healing watchdog for THIS refresh. Safe even if we
            // bail out below (e.g. missing credentials) — that path sets
            // isRefreshing=false, so the watchdog finds nothing stuck.
            let refreshGeneration = await self.tokenCoordinator.currentGeneration()
            self.scheduleTokenRefreshWatchdog(generation: refreshGeneration)

            // Use per-account instance to prevent TOCTOU races: without this,
            // another thread could switch libraryUUID between sharedAccount()
            // and the .username/.pin reads, sending Account B's credentials
            // to Account A's token endpoint.
            let snapshot = self.accountsManager.userAccount(for: capturedAccountId ?? self.accountsManager.currentAccountId ?? "").credentialSnapshot()
            guard let username = snapshot.barcode, !username.isEmpty,
                  let password = snapshot.pin,
                  let tokenURL = snapshot.authDefinition?.tokenURL else {
                Log.error(#file, "Cannot refresh token: missing credentials or tokenURL for account \(capturedAccountId ?? "nil")")
                await self.tokenCoordinator.setRefreshing(false)
                let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Cannot request token with empty credentials"])
                completionBox?.call(NYPLResult.failure(error, nil))
                return
            }

            let authType = snapshot.authDefinition?.authType.rawValue ?? "unknown"
            Log.info(#file, "Refreshing token for auth type: \(authType), account: \(capturedAccountId ?? "current")")

            if let task {
                await self.tokenCoordinator.appendToRetryQueue(task)
                if let completionBox {
                    self.responder.addCompletion(completionBox.call, taskID: task.taskIdentifier)
                }
            }

            self.executeTokenRefresh(username: username, password: password, tokenURL: tokenURL, accountId: capturedAccountId) { [weak self] result in
                guard let self else { return }
                // Box the non-`Sendable` `Result<TokenResponse, Error>` before the
                // `sending` `Task` closure below. `TokenResponse` is not yet
                // Sendable-audited upstream (PalaceAuth) and the `Error` existential
                // is never Sendable, so `result` cannot be captured directly into
                // the Task without the "passing closure as a 'sending' parameter"
                // diagnostic. The box is produced here and consumed exactly once
                // inside the Task — same isolation-preserving carrier pattern as
                // `CompletionBox`. Behavior unchanged.
                let resultBox = CompletionResultBox(result)
                Task {
                    switch resultBox.result {
                    case .success(let tokenResponse):
                        Log.info(#file, "Token refresh successful for account \(capturedAccountId ?? "current"), expires in \(tokenResponse.expiresIn)s")

                        let queuedTasks = await self.tokenCoordinator.drainRetryQueue()
                        let retryCount = queuedTasks.count
                        var newTasks = [URLSessionTask]()

                        for oldTask in queuedTasks {
                            guard let originalRequest = oldTask.originalRequest,
                                  let originalURL = originalRequest.url else {
                                continue
                            }

                            let mutableRequest = self.request(for: originalURL)
                            let newTask = self.transport.urlSession.dataTask(with: mutableRequest)
                            self.responder.updateCompletionId(oldTask.taskIdentifier, newId: newTask.taskIdentifier)
                            newTasks.append(newTask)
                            oldTask.cancel()
                        }

                        Log.info(#file, "Retrying \(retryCount) failed request(s) with new token")
                        newTasks.forEach { $0.resume() }

                        await self.tokenCoordinator.setRefreshing(false)

                        if task == nil {
                            completionBox?.call(NYPLResult.success(Data(), nil))
                        }

                    case .failure(let error):
                        Log.error(#file, "Failed to refresh token with error: \(error.localizedDescription)")

                        let failedTasks = await self.tokenCoordinator.drainRetryQueue()
                        failedTasks.forEach { $0.cancel() }

                        await self.tokenCoordinator.setRefreshing(false)

                        if let nsError = error as? NSError, nsError.code == 401 {
                            Log.info(#file, "Token refresh failed due to invalid credentials - marking credentials stale for account \(capturedAccountId ?? "current")")
                            await MainActor.run {
                                // capturedAccountId is bound at refresh-start time by the closure
                                // capture, so this mark-stale is already scoped to the originating
                                // account, not the current account at 401-receipt time. See
                                // .forgeos/changesets/fix-icarus-cross-host-logout/fix-contract.md.
                                // no-host-scoping: closure-bound capturedAccountId (see comment above)
                                self.accountsManager.userAccount(for: capturedAccountId ?? self.accountsManager.currentAccountId ?? "").markCredentialsStale()
                                if capturedAccountId == nil || capturedAccountId == self.accountsManager.currentAccountId {
                                    // swarm_d8f11437 Module A wave 4 — migrated to
                                    // AppContainer-injected sheet presenter.
                                    AppContainer.production().signInModalSheetPresenter
                                        .presentSignInModalForCurrentAccount(completion: nil)
                                }
                            }
                        }

                        // Preserve any RFC 7807 problem document that TokenRequest
                        // already embedded (e.g. "Expired Card") so the sign-in UI
                        // can show the server-supplied reason instead of falling
                        // back to "Invalid Credentials" on token refresh failure.
                        let userInfo: [String: Any] = [
                            NSLocalizedDescriptionKey: "Token refresh failed: \(error.localizedDescription)"
                        ]
                        let nsError: NSError
                        if let upstreamProblemDoc = (error as NSError).problemDocument {
                            nsError = NSError.makeFromProblemDocument(
                                upstreamProblemDoc,
                                domain: TPPErrorLogger.clientDomain,
                                code: TPPErrorCode.invalidCredentials.rawValue,
                                userInfo: userInfo)
                        } else {
                            nsError = NSError(domain: TPPErrorLogger.clientDomain,
                                              code: TPPErrorCode.invalidCredentials.rawValue,
                                              userInfo: userInfo)
                        }
                        completionBox?.call(NYPLResult.failure(nsError, nil))
                    }
                }
            }
        }
    }

    func executeTokenRefresh(username: String, password: String, tokenURL: URL, accountId: String? = nil, completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        guard !username.isEmpty else {
            // Note: empty password is valid for pinless libraries (PP-4045).
            // Only guard against empty username.
            Log.error(#file, "Cannot request token with empty username")
            let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "Cannot request token with empty username"])
            completion(.failure(error))
            return
        }

        let session = self.transport.urlSession
        // Box the non-`Sendable` completion so it can cross the `@Sendable` Task
        // boundary below; invoked exactly once.
        let completionBox = CompletionBox(completion)
        Task {
            let tokenRequest = TokenRequest(url: tokenURL, username: username, password: password)
            let result = await tokenRequest.execute(session: session)

            switch result {
            case .success(let tokenResponse):
                let targetAccount = self.accountsManager.userAccount(for: accountId ?? self.accountsManager.currentAccountId ?? "")
                targetAccount.setAuthToken(
                    tokenResponse.accessToken,
                    barcode: username,
                    pin: password,
                    expirationDate: tokenResponse.expirationDate
                )
                targetAccount.markLoggedIn()
                completionBox.call(.success(tokenResponse))
            case .failure(let error):
                completionBox.call(.failure(error))
            }
        }
    }
}

// MARK: - Continuation safety helper

/// Thread-safe one-shot guard for `withCheckedThrowingContinuation` bridges.
/// Calling `tryConsume()` returns `true` exactly once for the lifetime of the
/// instance; subsequent calls return `false`. Use to guarantee a continuation
/// is resumed at most once even if the underlying completion handler is
/// invoked multiple times by a buggy producer.
private final class ContinuationGuard {
    private var consumed = false
    private let lock = NSLock()
    func tryConsume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}

/// Bridges structured-concurrency cancellation into the completion-handler API.
///
/// A `CheckedContinuation` is resumed ONLY by its completion handler.
/// `Task.cancel()` sets a flag; it cannot resume a suspended continuation. So a
/// bare `withCheckedThrowingContinuation` bridge whose HTTP completion never
/// fires leaves the awaiting Task suspended forever — and, because every
/// `Task.isCancelled` check in a caller sits BETWEEN awaits, that task is
/// permanently undrainable. `AccountRegistryLoader`'s crawl hit exactly this:
/// `cancelAndDrainBackgroundWork TIMED OUT ... crawl did not observe cancellation`,
/// repeating every 3s and degrading a whole test run.
///
/// This box makes cancellation terminal from either side, resuming exactly once:
///   • the HTTP completion arrives  → `finish(_:)`
///   • the awaiting Task is cancelled → `cancel()` cancels the URLSession task
///     (when the underlying call exposes one) AND resumes with `CancellationError`.
///
/// Cancellation that arrives BEFORE the continuation is installed is retained
/// and applied on `install(_:)`, so the early-cancel race cannot strand a caller.
/// Mirrors `CancellableTaskBox` in `URLSessionNetworkClient`, which already
/// solved this for the newer client.
private final class CancellableContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var task: URLSessionTask?
    nonisolated(unsafe) private var pendingResult: Result<T, Error>?
    private var settled = false

    /// Install the continuation. If cancellation (or a completion) already
    /// landed, resume immediately rather than suspending forever.
    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Store the in-flight request so cancellation can tear it down. If
    /// cancellation already arrived, cancel it on the spot.
    func setTask(_ task: URLSessionTask?) {
        lock.lock()
        if settled {
            lock.unlock()
            task?.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    /// Resume with the network outcome. No-op once settled.
    func finish(_ result: sending Result<T, Error>) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        // Consume `result` on exactly ONE path. Storing it and also resuming
        // with it puts the same value in two regions, which the Swift 6 sending
        // check rejects (`T` is not constrained Sendable here).
        if let continuation {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }

    /// Cancel the request and unblock the awaiting Task.
    func cancel() {
        lock.lock()
        let inFlight = task
        task = nil
        lock.unlock()
        inFlight?.cancel()
        finish(.failure(CancellationError()))
    }
}

// MARK: - Async/Await API

extension TPPNetworkExecutor {

    /// Async version of GET that bridges to the completion-handler API.
    /// Timeout is handled by the URLSession configuration, not by a manual timer.
    ///
    /// `CancellableContinuationBox` makes the bridge cancellation-aware AND
    /// resume-exactly-once (superseding the old `ContinuationGuard` here). Note
    /// this overload's underlying call returns no `URLSessionDataTask`, so the
    /// HTTP request is not torn down — but the awaiting Task is still unblocked,
    /// which is what makes it drainable. A stray late completion is swallowed by
    /// the box.
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool = true) async throws -> (Data, URLResponse?) {
        let box = CancellableContinuationBox<(Data, URLResponse?)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                GET(reqURL, useTokenIfAvailable: useTokenIfAvailable) { result in
                    switch result {
                    case let .success(data, response):
                        box.finish(.success((data, response)))
                    case let .failure(error, _):
                        box.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Async version of GET with full request control.
    func GET(request: URLRequest, cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        let box = CancellableContinuationBox<(Data, URLResponse?)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                let task = GET(request: request, cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                    if let error = error {
                        box.finish(.failure(error))
                    } else {
                        box.finish(.success((data ?? Data(), response)))
                    }
                }
                box.setTask(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Async version of PUT.
    func PUT(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        let box = CancellableContinuationBox<(Data, URLResponse?)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                let task = PUT(reqURL, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                    if let error = error {
                        box.finish(.failure(error))
                    } else {
                        box.finish(.success((data ?? Data(), response)))
                    }
                }
                box.setTask(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Async version of POST.
    func POST(_ request: URLRequest, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        let box = CancellableContinuationBox<(Data, URLResponse?)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                let task = POST(request, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                    if let error = error {
                        box.finish(.failure(error))
                    } else {
                        box.finish(.success((data ?? Data(), response)))
                    }
                }
                box.setTask(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Async version of DELETE.
    func DELETE(_ request: URLRequest, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        let box = CancellableContinuationBox<(Data, URLResponse?)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                let task = DELETE(request, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                    if let error = error {
                        box.finish(.failure(error))
                    } else {
                        box.finish(.success((data ?? Data(), response)))
                    }
                }
                box.setTask(task)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

// Wave 1c (cycle 3): package-protocol seam — authorized-request derivation for
// the circulation-analytics offline enqueue. Distinct name: `request(for:)`'s
// defaulted `useTokenIfAvailable` param means it cannot witness a protocol
// requirement directly.
extension TPPNetworkExecutor: AuthorizedRequestProviding {
    func authorizedRequest(for url: URL) -> URLRequest {
        request(for: url)
    }
}
