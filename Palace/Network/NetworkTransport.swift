//
//  NetworkTransport.swift
//  The Palace Project
//
//  Pure-transport HTTP layer. Owns the URLSession, manages active tasks
//  (pause / resume / cancel-on-account-switch), and exposes send/download
//  primitives. Knows nothing about credentials, tokens, or sign-in modals —
//  those concerns live in TPPNetworkExecutor (the auth-aware client) which
//  wraps a Transport.
//
//  The split exists so the transport half is portable into the PalaceNetwork
//  SPM module, while the auth half stays in the app target where it can
//  reach AccountsManager / TPPUserAccount / SignInModalPresenter.
//

import Foundation
import PalaceLogging

/// Lock-protected store for the URLSession's active tasks list.
///
/// Intentionally NOT an actor: callers (most importantly `cancelNonEssentialTasks`
/// during account switches) need synchronous completion before the caller
/// proceeds — a fire-and-forget `Task { await actor.… }` would silently break
/// that invariant and let in-flight requests complete against the wrong
/// account's credentials.
final class ActiveTasksStore {
    private var tasks: [URLSessionTask] = []
    private let lock = NSLock()

    func add(_ task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        tasks.append(task)
    }

    func remove(_ task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        if let index = tasks.firstIndex(of: task) {
            tasks.remove(at: index)
        }
    }

    func pauseNonAudioTasks() {
        lock.lock(); defer { lock.unlock() }
        for task in tasks {
            if let url = task.originalRequest?.url,
               Self.isAudiobookRelated(url: url) {
                Log.info(#function, "Preserving audiobook network task: \(url.absoluteString)")
                continue
            }
            task.suspend()
        }
    }

    func resumeAll() {
        lock.lock(); defer { lock.unlock() }
        tasks.forEach { $0.resume() }
    }

    @discardableResult
    func cancelNonEssential() -> Int {
        lock.lock(); defer { lock.unlock() }
        let toCancel = tasks.filter { task in
            guard let url = task.originalRequest?.url else { return true }
            return !Self.isAudiobookRelated(url: url)
        }
        toCancel.forEach { $0.cancel() }
        tasks.removeAll { toCancel.contains($0) }
        return toCancel.count
    }

    private static func isAudiobookRelated(url: URL) -> Bool {
        let s = url.absoluteString
        return s.contains("audiobook") ||
            s.contains(".mp3") ||
            s.contains(".m4a") ||
            s.contains("audio") ||
            s.contains("readium") ||
            s.contains("lcp")
    }
}

/// Pure HTTP transport. Owns a URLSession and an active-tasks registry.
/// Auth, retries, and credential plumbing live above this layer.
@objc final class NetworkTransport: NSObject {
    #if DEBUG
    private(set) var urlSession: URLSession
    #else
    let urlSession: URLSession
    #endif

    let activeTasksStore = ActiveTasksStore()

    private let cachingStrategy: NYPLCachingStrategy
    private let requestTimeout: TimeInterval
    private let delegateQueue: OperationQueue?
    private weak var delegate: URLSessionDelegate?

    init(delegate: URLSessionDelegate?,
         cachingStrategy: NYPLCachingStrategy,
         requestTimeout: TimeInterval,
         delegateQueue: OperationQueue? = nil) {
        self.cachingStrategy = cachingStrategy
        self.requestTimeout = requestTimeout
        self.delegateQueue = delegateQueue
        self.delegate = delegate
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: cachingStrategy,
            requestTimeout: requestTimeout)
        self.urlSession = URLSession(configuration: config,
                                     delegate: delegate,
                                     delegateQueue: delegateQueue)
        super.init()
    }

    /// Test-friendly initializer with an explicit URLSessionConfiguration
    /// (e.g. one that registers a custom URLProtocol class).
    init(delegate: URLSessionDelegate?,
         sessionConfiguration: URLSessionConfiguration,
         delegateQueue: OperationQueue? = nil,
         cachingStrategy: NYPLCachingStrategy = .fallback,
         requestTimeout: TimeInterval) {
        self.cachingStrategy = cachingStrategy
        self.requestTimeout = requestTimeout
        self.delegateQueue = delegateQueue
        self.delegate = delegate
        self.urlSession = URLSession(configuration: sessionConfiguration,
                                     delegate: delegate,
                                     delegateQueue: delegateQueue)
        super.init()
    }

    deinit {
        urlSession.finishTasksAndInvalidate()
    }

    // MARK: - Session lifecycle

    /// Default URLSession config the transport will use when caller doesn't
    /// supply a custom one. Exposed for callers that need to inspect cache
    /// policy without poking at `urlSession.configuration`.
    var requestCachePolicy: NSURLRequest.CachePolicy {
        urlSession.configuration.requestCachePolicy
    }

    #if DEBUG
    /// Recreate the URLSession to pick up newly-registered URLProtocol classes
    /// (e.g. MockBackendURLProtocol). Called by MockBackendService when
    /// activating/deactivating the mock backend.
    func recreateSession() {
        urlSession.finishTasksAndInvalidate()
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: cachingStrategy,
            requestTimeout: requestTimeout)
        urlSession = URLSession(configuration: config,
                                delegate: delegate,
                                delegateQueue: delegateQueue)
        Log.info(#file, "NetworkTransport: session recreated")
    }
    #endif

    // MARK: - Send / download

    /// Create + resume a data task. The task is auto-registered in the active
    /// tasks store so it participates in pause/resume/cancel.
    @discardableResult
    func send(_ request: URLRequest) -> URLSessionDataTask {
        let task = urlSession.dataTask(with: request)
        activeTasksStore.add(task)
        task.resume()
        return task
    }

    /// Create + resume a download task. Not added to the active-tasks store
    /// today — historical behavior; callers manage download lifecycle directly.
    @discardableResult
    func download(_ request: URLRequest) -> URLSessionDownloadTask {
        let task = urlSession.downloadTask(with: request)
        task.resume()
        return task
    }

    // MARK: - Active tasks control

    @objc func pauseAllTasks() {
        activeTasksStore.pauseNonAudioTasks()
    }

    @objc func resumeAllTasks() {
        activeTasksStore.resumeAll()
    }

    /// Cancels all active tasks not related to audiobook streaming. Called
    /// during account switches to prevent in-flight requests from completing
    /// against the wrong account's credentials. Synchronous on purpose — see
    /// `ActiveTasksStore` doc-comment.
    @objc func cancelNonEssentialTasks() {
        let count = activeTasksStore.cancelNonEssential()
        Log.info(#file, "Cancelled \(count) non-essential tasks during account switch")
    }

    // MARK: - Cache

    @objc func clearCache() {
        urlSession.configuration.urlCache?.removeAllCachedResponses()
    }
}
