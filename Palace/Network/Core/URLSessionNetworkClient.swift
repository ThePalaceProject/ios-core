//
//  URLSessionNetworkClient.swift
//  Palace
//

import Foundation
import PalaceNetwork

final class URLSessionNetworkClient: NetworkClient {
    private let executor: TPPNetworkExecutor

    init(executor: TPPNetworkExecutor) {
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

        // Don't open a connection, or start a token refresh, for work nobody
        // is waiting on.
        try Task.checkCancellation()

        // `execute` is the executor's cancellable entry point: a cancel frees
        // the URLSession task and its connection-pool slot (#1116), and during
        // a proactive token refresh it frees the caller and nothing is sent
        // afterwards. The callback verbs return no task while a refresh runs,
        // so they cannot be cancelled in that window.
        let enableTokenRefresh: Bool
        switch request.method {
        case .GET, .HEAD:
            // As the executor's GET verb: always sent as GET, with the
            // protocol cache policy.
            urlRequest.httpMethod = "GET"
            urlRequest.cachePolicy = .useProtocolCachePolicy
            enableTokenRefresh = true

        case .POST, .PUT:
            enableTokenRefresh = true

        case .PATCH:
            // As `addBearerAndExecute`: the Authorization header is replaced
            // and the proactive near-expiry refresh is skipped. A 401 is still
            // offered to the responder's reactive refresh, which declines for
            // browser (SAML/OIDC) auth among other cases; see
            // `handleExpiredTokenIfNeeded`.
            urlRequest = TPPNetworkExecutor.bearerAuthorized(request: urlRequest)
            enableTokenRefresh = false

        case .DELETE:
            // The executor's DELETE verb never refreshes proactively.
            enableTokenRefresh = false
        }

        switch await executor.execute(urlRequest, enableTokenRefresh: enableTokenRefresh, accountId: nil) {
        case let .success(data, response):
            guard let response = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
            return NetworkResponse(data: data, response: response)
        case let .failure(error, _):
            throw error
        }
    }
}
