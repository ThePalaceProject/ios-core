//
//  NetworkClient.swift
//  Palace
//
//

import Foundation

// MARK: - NetworkClient

public protocol NetworkClient {
  func send(_ request: NetworkRequest) async throws -> NetworkResponse
}

// MARK: - NetworkRequest

public struct NetworkRequest {
  public var method: HTTPMethod
  public var url: URL
  public var headers: [String: String]
  public var body: Data?

  public init(method: HTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

// MARK: - NetworkResponse

public struct NetworkResponse {
  public let data: Data
  public let response: HTTPURLResponse
}

// MARK: - HTTPMethod

public enum HTTPMethod: String {
  case GET
  case POST
  case PUT
  case PATCH
  case DELETE
  case HEAD
}
