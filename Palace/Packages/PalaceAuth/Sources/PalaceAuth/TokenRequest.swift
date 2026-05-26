//
//  TokenRequest.swift
//  Palace
//
//  Created by Maurice Carrier on 6/28/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceCatalog

@objcMembers public class TokenResponse: NSObject, Codable {
    @objc public let accessToken: String
    public let tokenType: String
    @objc public let expiresIn: Int

    @objc public init(accessToken: String, tokenType: String, expiresIn: Int) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }
}

@objc public extension TokenResponse {
    var expirationDate: Date {
        Date(timeIntervalSinceNow: Double(expiresIn))
    }
}

@objcMembers public class TokenRequest: NSObject {
    public let url: URL
    public let username: String
    public let password: String

    @objc public init(url: URL, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    public func execute(session: URLSession = .shared) async -> Result<TokenResponse, Error> {
        Log.info(#file, "Requesting token from: \(url.absoluteString)")

        let looksLikeBarcode = username.allSatisfy({ $0.isNumber }) && username.count >= 5
        let looksLikeOAuthToken = username.count > 50 || username.contains(".")
        Log.info(#file, "  Credential shape: usernameLen=\(username.count), pinLen=\(password.count), looksLikeBarcode=\(looksLikeBarcode), looksLikeOAuthToken=\(looksLikeOAuthToken)")

        guard !username.isEmpty else {
            Log.error(#file, "Aborting token request: empty username")
            return .failure(NSError(domain: "TokenRequest", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Cannot request token with empty username"]))
        }
        // Note: empty password is valid for libraries that don't require a PIN.
        // Basic Auth with "barcode:" (empty password) is the correct format for
        // pinless authentication. The original guard (!password.isEmpty) broke
        // pinless login for libraries like Wolcott Public Library and Bentley
        // Memorial Library (PP-4045).

        // Build the request directly — the main-target `URLRequest(url:applyingCustomUserAgent:)`
        // initializer is not available in the package. Disable optimistic HTTP/3
        // (some library servers advertise h3 with a broken QUIC implementation
        // that wastes ~260ms before falling back to h2); main-target callers
        // can layer the custom User-Agent in via `applyCustomUserAgent()` on
        // the resulting request before mutating it.
        var request = URLRequest(url: url)
        request.assumesHTTP3Capable = false
        request.httpMethod = "POST"

        let loginString = "\(username):\(password)"
        guard let loginData = loginString.data(using: .utf8) else {
            Log.error(#file, "Failed to encode credentials - contains non-UTF8 characters?")
            return .failure(URLError(.badURL))
        }
        let base64LoginString = loginData.base64EncodedString()
        request.addValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")

        Log.debug(#file, "Sending POST with Basic Auth (base64 len=\(base64LoginString.count))")

        do {
            let (data, response) = try await session.data(for: request)

            Log.info(#file, "Token request returned \(data.count) bytes")

            if let httpResponse = response as? HTTPURLResponse {
                Log.info(#file, "Token request status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    let errorMsg = String(data: data, encoding: .utf8) ?? "No error message"
                    Log.error(#file, "Token request failed with status \(httpResponse.statusCode): \(errorMsg)")
                    return .failure(NSError.makeTokenRequestHTTPError(
                        data: data,
                        statusCode: httpResponse.statusCode,
                        domain: "TokenRequest",
                        userInfo: [NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode)"]))
                }
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
            Log.info(#file, "Successfully decoded token response, expires in \(tokenResponse.expiresIn)s")
            return .success(tokenResponse)
        } catch {
            Log.error(#file, "Token request failed with error: \(error.localizedDescription)")
            if let urlError = error as? URLError {
                Log.error(#file, "URLError code: \(urlError.code.rawValue)")
            }
            if let decodingError = error as? DecodingError {
                Log.error(#file, "Decoding error: \(decodingError)")
            }
            return .failure(error)
        }
    }
}

extension TokenRequest {
    @objc public func execute(completion: @escaping (TokenResponse?, Error?) -> Void) {
        Task {
            let result = await execute()
            switch result {
            case .success(let tokenResponse):
                completion(tokenResponse, nil)
            case .failure(let error):
                completion(nil, error)
            }
        }
    }
}

// MARK: - Problem-document-aware NSError factory (package-local)
//
// Mirrors `NSError.makeFromHTTPResponse(data:statusCode:domain:userInfo:)`
// from the main target's `Palace/Network/TPPUserFriendlyError.swift`. That
// extension is not visible to PalaceAuth, so this package-private factory
// preserves the same RFC-7807 ProblemDocument embedding the legacy
// `userFacingSignInError` UI layer reads via `problemDocument` /
// `userFriendlyTitle` / `userFriendlyMessage`. Reaches into `PalaceCatalog`
// for the parser, which PalaceAuth already depends on. Keeping it private
// to TokenRequest's file means we only export the behavior, not a new
// public surface on `NSError`.
private extension NSError {
    static func makeTokenRequestHTTPError(data: Data,
                                          statusCode: Int,
                                          domain: String,
                                          userInfo: [String: Any]? = nil) -> NSError {
        if let problemDoc = TPPProblemDocument.fromProblemResponseData(data) {
            var info = userInfo ?? [String: Any]()
            // Same key the main-target extension uses for the embedded
            // ProblemDocument so `userFriendlyTitle` / `userFriendlyMessage`
            // resolve consistently in both code paths.
            info["problemDocument"] = problemDoc
            return NSError(domain: domain, code: statusCode, userInfo: info)
        }
        return NSError(domain: domain, code: statusCode, userInfo: userInfo)
    }
}
