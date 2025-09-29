//
//  URLSessionNetworkClient.swift
//  Palace
//

import Foundation

final class URLSessionNetworkClient: NetworkClient {
  private let executor: TPPNetworkExecutor

  init(executor: TPPNetworkExecutor = .shared) {
    self.executor = executor
  }

  enum NetworkError: Error, LocalizedError {
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .invalidURL: "Invalid request URL."
      case .invalidResponse: "Invalid or missing HTTP response."
      }
    }
  }

  func send(_ request: NetworkRequest) async throws -> NetworkResponse {
    guard let url = URL(string: request.url.absoluteString) else {
      throw NetworkError.invalidURL
    }
    var urlRequest = executor.request(for: url)
    urlRequest.httpMethod = request.method.rawValue
    request.headers.forEach { key, value in
      urlRequest.setValue(value, forHTTPHeaderField: key)
    }
    urlRequest.httpBody = request.body

    let (data, response) = try await withCheckedThrowingContinuation { continuation in
      let completion: (NYPLResult<Data>) -> Void = { result in
        switch result {
        case let .success(data, response):
          if let http = response as? HTTPURLResponse {
            continuation.resume(returning: (data, http))
          } else {
            let err = NSError(
              domain: NSURLErrorDomain,
              code: NSURLErrorUnknown,
              userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
            )
            continuation.resume(throwing: err)
          }
        case let .failure(error, _):
          continuation.resume(throwing: error)
        }
      }

      switch request.method {
      case .GET, .HEAD:
        _ = self.executor.GET(urlRequest.url!, useTokenIfAvailable: true) { data, response, error in
          if let error {
            continuation.resume(throwing: error); return
          }
          guard let data = data,
                let response = response as? HTTPURLResponse
          else {
            continuation.resume(throwing: NetworkError.invalidResponse); return
          }
          continuation.resume(returning: (data, response))
        }

      case .POST:
        _ = self.executor.POST(urlRequest, useTokenIfAvailable: true) { data, response, error in
          if let error {
            continuation.resume(throwing: error); return
          }
          guard let data = data,
                let response = response as? HTTPURLResponse
          else {
            continuation.resume(throwing: NetworkError.invalidResponse); return
          }
          continuation.resume(returning: (data, response))
        }

      case .PUT:
        _ = self.executor.PUT(request: urlRequest, useTokenIfAvailable: true) { data, response, error in
          if let error {
            continuation.resume(throwing: error); return
          }
          guard let data = data,
                let response = response as? HTTPURLResponse
          else {
            continuation.resume(throwing: NetworkError.invalidResponse); return
          }
          continuation.resume(returning: (data, response))
        }

      case .PATCH:
        // Executor has no PATCH; emulate via POST with method override header
        var patched = urlRequest
        patched.httpMethod = "PATCH"
        _ = self.executor.addBearerAndExecute(patched) { data, response, error in
          if let error {
            continuation.resume(throwing: error); return
          }
          guard let data = data,
                let response = response as? HTTPURLResponse
          else {
            continuation.resume(throwing: NetworkError.invalidResponse); return
          }
          continuation.resume(returning: (data, response))
        }

      case .DELETE:
        _ = self.executor.DELETE(urlRequest, useTokenIfAvailable: true) { data, response, error in
          if let error {
            continuation.resume(throwing: error); return
          }
          guard let data = data,
                let response = response as? HTTPURLResponse
          else {
            continuation.resume(throwing: NetworkError.invalidResponse); return
          }
          continuation.resume(returning: (data, response))
        }
      }
    }

    return NetworkResponse(data: data, response: response)
  }
}
