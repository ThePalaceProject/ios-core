//
//  URLSessionNetworkClient.swift
//  Palace
//

import Foundation
import PalaceNetwork

final class URLSessionNetworkClient: NetworkClient {
    private let executor: TPPNetworkExecutor

    init(executor: TPPNetworkExecutor = AppContainer.production().networkExecutor) {
        self.executor = executor
    }

    enum NetworkError: Error, LocalizedError {
        case invalidURL
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid request URL."
            case .invalidResponse: return "Invalid or missing HTTP response."
            }
        }
    }

    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        guard let url = URL(string: request.url.absoluteString) else { throw NetworkError.invalidURL }
        var urlRequest = executor.request(for: url)
        urlRequest.httpMethod = request.method.rawValue
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        // Bridges Swift structured-concurrency cancellation to the underlying
        // URLSession task. See `CancellableTaskBox` for why this matters.
        let taskBox = CancellableTaskBox()

        let (data, response): (Data, HTTPURLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                // If the awaiting Task was already cancelled, don't even open a
                // connection for work nobody is waiting on.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                func resume(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
                    if let error { continuation.resume(throwing: error); return }
                    guard let data, let response = response as? HTTPURLResponse else {
                        continuation.resume(throwing: NetworkError.invalidResponse); return
                    }
                    continuation.resume(returning: (data, response))
                }

                let dataTask: URLSessionDataTask?
                switch request.method {
                case .GET, .HEAD:
                    dataTask = self.executor.GET(request: urlRequest, useTokenIfAvailable: true) { resume($0, $1, $2) }

                case .POST:
                    dataTask = self.executor.POST(urlRequest, useTokenIfAvailable: true) { resume($0, $1, $2) }

                case .PUT:
                    dataTask = self.executor.PUT(request: urlRequest, useTokenIfAvailable: true) { resume($0, $1, $2) }

                case .PATCH:
                    // Executor has no PATCH; emulate via POST with method override header
                    var patched = urlRequest
                    patched.httpMethod = "PATCH"
                    dataTask = self.executor.addBearerAndExecute(patched) { resume($0, $1, $2) }

                case .DELETE:
                    dataTask = self.executor.DELETE(urlRequest, useTokenIfAvailable: true) { resume($0, $1, $2) }
                }

                // Hand the live URLSession task to the cancellation box. If
                // cancellation raced ahead of task creation, this cancels it
                // immediately (freeing the connection-pool slot).
                taskBox.set(dataTask)
            }
        } onCancel: {
            taskBox.cancel()
        }

        return NetworkResponse(data: data, response: response)
    }
}

/// Thread-safe holder that bridges structured-concurrency cancellation to the
/// underlying `URLSessionTask`.
///
/// Previously `send` discarded the task returned by the executor
/// (`_ = executor.GET(...)`) and installed no cancellation handler, so a
/// cancelled or timed-out catalog/lane fetch kept its socket open until the
/// shared session's resource timeout. Because most Palace libraries share one
/// Circulation Manager host, a handful of stuck requests could exhaust that
/// host's connection pool and starve *every* library's feed fetches — the
/// "catalog hangs until a wifi-switch or app restart" failure. Cancelling the
/// task here releases the slot immediately.
private final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    /// Store the in-flight task, or cancel it on the spot if cancellation
    /// already arrived before the task existed.
    func set(_ task: URLSessionTask?) {
        lock.lock(); defer { lock.unlock() }
        if isCancelled { task?.cancel() } else { self.task = task }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        isCancelled = true
        task?.cancel()
        task = nil
    }
}
