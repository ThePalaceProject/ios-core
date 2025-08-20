//
//  NetworkClient.swift
//  Palace
//
//  Created as part of networking unification.
//

import Foundation

public protocol NetworkClient {
  func send(_ request: NetworkRequest) async throws -> NetworkResponse
}

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

public struct NetworkResponse {
  public let data: Data
  public let response: HTTPURLResponse
}

public enum HTTPMethod: String {
  case GET, POST, PUT, PATCH, DELETE, HEAD
}


