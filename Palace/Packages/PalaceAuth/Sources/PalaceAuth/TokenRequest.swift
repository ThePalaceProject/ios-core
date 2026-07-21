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

@objcMembers public class TokenResponse: NSObject, Codable, @unchecked Sendable { // : all stored properties are immutable `let`s
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

// `Sendable`: immutable value-typed `let` storage only; the Task in
// `execute(completion:)` captures `self` to drive the async POST. `final` makes
// the checked conformance sound (no subclasses exist).
@objcMembers public final class TokenRequest: NSObject, Sendable {
    public let url: URL
    public let username: String
    public let password: String

    @objc public init(url: URL, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    // PUBLIC_INTENT: shared error-domain constant so the producer (this type)
    // and the main-target consumer (TPPSignInBusinessLogic.isTransientServerError)
    // agree on the NSError domain at COMPILE time. Was a duplicated magic string
    // ("TokenRequest") across two files — architect review rev_37c23a0e flagged
    // that a rename in one place would silently regress the 18046 fix.
    public static let httpErrorDomain = "TokenRequest"

    /// Public entry point — single Basic-Auth POST to the /token endpoint, now
    /// with bounded retry on TRANSIENT failures (HelpSpot 18046). A transient
    /// server hiccup (intermittent 5xx/429/408) or a retriable network error no
    /// longer surfaces as "Invalid Credentials" on the first try; genuine auth
    /// failures (401/403) still fail immediately and are never retried.
    public func execute(session: URLSession = .shared) async -> Result<TokenResponse, Error> {
        await execute(session: session, maxAttempts: 3, backoff: Self.defaultBackoff)
    }

    /// Injectable overload (internal — reached by tests via `@testable`). Keeps
    /// `maxAttempts` / `backoff` out of the public surface while letting tests
    /// drive the retry loop deterministically with a no-op backoff.
    func execute(session: URLSession,
                 maxAttempts: Int,
                 backoff: @Sendable (Int) async -> Void) async -> Result<TokenResponse, Error> {
        Log.info(#file, "Requesting token from: \(url.absoluteString)")

        let looksLikeBarcode = username.allSatisfy({ $0.isNumber }) && username.count >= 5
        let looksLikeOAuthToken = username.count > 50 || username.contains(".")
        Log.info(#file, "  Credential shape: usernameLen=\(username.count), pinLen=\(password.count), looksLikeBarcode=\(looksLikeBarcode), looksLikeOAuthToken=\(looksLikeOAuthToken)")

        guard !username.isEmpty else {
            Log.error(#file, "Aborting token request: empty username")
            return .failure(NSError(domain: Self.httpErrorDomain, code: -1,
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

        let attempts = max(1, maxAttempts)
        var lastError: Error = NSError(domain: Self.httpErrorDomain, code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "Token request did not complete"])

        for attempt in 1...attempts {
            do {
                let (data, response) = try await session.data(for: request)
                Log.info(#file, "Token request returned \(data.count) bytes (attempt \(attempt)/\(attempts))")

                if let httpResponse = response as? HTTPURLResponse {
                    Log.info(#file, "Token request status: \(httpResponse.statusCode)")
                    if httpResponse.statusCode != 200 {
                        let errorMsg = String(data: data, encoding: .utf8) ?? "No error message"
                        let httpError = NSError.makeTokenRequestHTTPError(
                            data: data,
                            statusCode: httpResponse.statusCode,
                            domain: Self.httpErrorDomain,
                            userInfo: [NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode)"])
                        // Retry only transient infrastructure failures. A 401/403
                        // is a genuine auth rejection — surface it immediately so
                        // we never hammer the endpoint with bad credentials.
                        if Self.isTransientStatus(httpResponse.statusCode), attempt < attempts {
                            Log.warn(#file, "Transient token status \(httpResponse.statusCode) — retrying after backoff (attempt \(attempt)/\(attempts))")
                            lastError = httpError
                            await backoff(attempt)
                            continue
                        }
                        Log.error(#file, "Token request failed with status \(httpResponse.statusCode): \(errorMsg)")
                        return .failure(httpError)
                    }
                }

                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
                Log.info(#file, "Successfully decoded token response, expires in \(tokenResponse.expiresIn)s")
                return .success(tokenResponse)
            } catch {
                // Retriable transport error (timeout, connection dropped, DNS):
                // back off and try again. A non-retriable error (e.g. decoding,
                // bad URL, hard offline) fails immediately.
                if Self.isRetriableURLError(error), attempt < attempts {
                    Log.warn(#file, "Transient network error on token request — retrying after backoff (attempt \(attempt)/\(attempts)): \(error.localizedDescription)")
                    lastError = error
                    await backoff(attempt)
                    continue
                }
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

        return .failure(lastError)
    }

    /// Default backoff between retry attempts: short, linear, capped — login is
    /// interactive, so we trade a little latency for resilience without stalling.
    static let defaultBackoff: @Sendable (Int) async -> Void = { attempt in
        let milliseconds = min(2000, 400 * attempt)
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    /// HTTP statuses worth retrying: request timeout, rate-limit, and any 5xx.
    /// Deliberately EXCLUDES 401/403 (genuine auth) and other 4xx (client error).
    static func isTransientStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    /// Transport-level errors worth retrying. Excludes `.notConnectedToInternet`
    /// (hard offline — fast-fail to the network-unavailable message) and
    /// non-`URLError`s (e.g. decoding).
    static func isRetriableURLError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .cannotFindHost, .resourceUnavailable,
             .badServerResponse:
            return true
        default:
            return false
        }
    }
}

extension TokenRequest {
    @objc public func execute(completion: @escaping @Sendable (TokenResponse?, Error?) -> Void) {
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
