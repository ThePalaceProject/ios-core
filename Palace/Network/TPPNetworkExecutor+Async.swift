//
//  TPPNetworkExecutor+Async.swift
//  Palace
//
//  The executor's awaited entry points. Split out of `TPPNetworkExecutor.swift`
//  so that file stays under its code-line ceiling; the callback forms these
//  bridge to, and the shared `preflight` both use, remain there.
//
//  Every overload here resumes on the awaiting caller's actor, which is the
//  reason callers are being moved onto them (PP-5301): a completion parameter
//  carries no isolation, so a closure formed in a `@MainActor` context inherits
//  that isolation while the network layer delivers off it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

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

    /// Refresh the account token for `accountId` and report the outcome.
    ///
    /// `refreshTokenAndResume`'s completion fires from inside that method's own
    /// `Task`, i.e. the cooperative pool, so a caller on an actor had to hop
    /// the outcome itself — `AudiobookLoader` crashed in 3.3.0 for not doing so
    /// at one exit (PP-5299). Awaiting resumes on the caller's actor instead,
    /// which is why the loader no longer carries a hop.
    ///
    /// `presentsSignInOnFailure` is not exposed: every awaiting caller handles
    /// its own failure, and the default is what the callback form already used.
    /// Awaited `GET` that reports an `NYPLResult` rather than throwing.
    ///
    /// Distinct from the `async throws` `GET` overloads above because the
    /// failure case has to carry the `URLResponse`: callers read problem
    /// documents and status codes off error responses, and `throws` discards
    /// them. Named rather than overloaded on return type so no call site
    /// resolves to the wrong one by inference.
    ///
    /// This is the shape the completion-handler
    /// `GET(_:useTokenIfAvailable:completion:)` had, so a caller moving to it
    /// changes only how the answer arrives (PP-5301) — on the caller's own
    /// actor, instead of on whichever executor the network layer finished on.
    func fetchResult(from reqURL: URL, useTokenIfAvailable: Bool = true) async -> NYPLResult<Data> {
        let req = request(for: reqURL, useTokenIfAvailable: useTokenIfAvailable)
        return await execute(req, enableTokenRefresh: useTokenIfAvailable, accountId: nil)
    }

    func refreshToken(accountId: String?) async -> NYPLResult<Data> {
        let box = CancellableContinuationBox<RefreshOutcomeBox>()
        do {
            let outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    box.install(continuation)
                    refreshTokenAndResume(task: nil, accountId: accountId) { result in
                        box.finish(.success(RefreshOutcomeBox(result)))
                    }
                }
            } onCancel: {
                box.cancel()
            }
            return outcome.value
        } catch {
            return .failure(error as NSError, nil)
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
