//
//  NYPLOAuth2Error.swift
//  OverdriveProcessor
//
//  Created by Ettore Pasquini on 11/16/21.
//  Copyright © 2021 NYPL. All rights reserved.
//

import Foundation

//
// TODO: IOS-294 Move to a shared Simplified-iOS-Utilities module.
//

/// This enum maps all possible OAuth2 error codes.
///
/// Reference:  https://datatracker.ietf.org/doc/html/rfc6749#section-4.1.2.1
public enum NYPLOAuth2ErrorCode: String, Decodable {
  case invalidRequest = "invalid_request"
  case invalidClient = "invalid_client"
  case invalidGrant = "invalid_grant"
  case unauthorizedClient = "unauthorized_client"
  case unsupportedGrantType = "unsupported_grant_type"
  case invalidScope = "invalid_scope"

  public var intValue: Int {
    switch self {
    case .invalidRequest: return 10000
    case .invalidClient: return 10001
    case .invalidGrant: return 10002
    case .unauthorizedClient: return 10003
    case .unsupportedGrantType: return 10004
    case .invalidScope: return 10005
    }
  }
}

public struct NYPLOAuth2Error: Decodable {
  public let errorCode: NYPLOAuth2ErrorCode
  public let errorDescription: String?
  public let errorUri: String?

  private enum CodingKeys: String, CodingKey {
    case errorCode = "error"
    case errorDescription
    case errorUri
  }

  public static func fromData(_ data: Data) throws -> NYPLOAuth2Error {
    let jsonDecoder = JSONDecoder()
    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    return try jsonDecoder.decode(NYPLOAuth2Error.self, from: data)
  }

  public func nsError(forRequest req: URLRequest, response: HTTPURLResponse) -> NSError {
    return NSError(domain: "OAuth2 Error",
                   code: errorCode.intValue,
                   userInfo: ["errorCodeString": errorCode.rawValue,
                              "errorDescription": errorDescription ?? "",
                              "errorUri": errorUri ?? "",
                              "request": req.loggableString,
                              "response": response.statusCode
                             ])
  }
}

extension URLRequest {
  /// Since a request can include sensitive data such as access tokens, etc,
  /// this computed variable includes a "safe" set of data that we can log.
  var loggableString: String {
    let methodAndURL = "\(httpMethod ?? "") \(url?.absoluteString ?? "")"
    let headers = allHTTPHeaderFields?.filter {
      $0.key.lowercased() != "authorization"
    } ?? [:]

    return "\(methodAndURL)\n  headers: \(headers)"
  }
}

