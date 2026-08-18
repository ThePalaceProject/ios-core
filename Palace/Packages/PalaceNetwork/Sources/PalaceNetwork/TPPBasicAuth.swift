//
//  TPPBasicAuth.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 02/07/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

/// Defines the interface required by the various pieces of the sign-in logic
/// to obtain the credentials for performing basic authentication.
@objc public protocol NYPLBasicAuthCredentialsProvider: NSObjectProtocol {
    var username: String? {get}
    var pin: String? {get}
}

@objc public class TPPBasicAuth: NSObject {
    public typealias BasicAuthCompletionHandler = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    /// The object providing the credentials to respond to the authentication
    /// challenge.
    private var credentialsProvider: NYPLBasicAuthCredentialsProvider

    @objc(initWithCredentialsProvider:)
    public init(credentialsProvider: NYPLBasicAuthCredentialsProvider) {
        self.credentialsProvider = credentialsProvider
        super.init()
    }

    /// Responds to the authentication challenge synchronously.
    /// - Parameters:
    ///   - challenge: The authentication challenge to respond to.
    ///   - completion: Always called, synchronously.
    /// COUPLED (PP-4969): `MyBooksDownloadCenter+ChallengeAccount.swift` skips its
    /// account lookup for any protection space this switch answers WITHOUT
    /// reading `credentialsProvider` — today everything except HTTP basic. Adding
    /// a credential-consuming space here means updating that guard too, or the
    /// download path will answer the new space with the wrong account.
    @objc public func handleChallenge(_ challenge: URLAuthenticationChallenge,
                                      completion: BasicAuthCompletionHandler) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic:
            guard
                let username = credentialsProvider.username,
                let password = credentialsProvider.pin,
                challenge.previousFailureCount == 0 else {
                completion(.cancelAuthenticationChallenge, nil)
                return
            }

            let credentials = URLCredential(user: username,
                                            password: password,
                                            persistence: .none)
            completion(.useCredential, credentials)

        case NSURLAuthenticationMethodServerTrust:
            completion(.performDefaultHandling, nil)

        default:
            completion(.rejectProtectionSpace, nil)
        }
    }

    /// Returns the answer to `challenge` directly, for the `async` URLSession
    /// delegate callbacks.
    ///
    /// Those callbacks return their disposition rather than passing it to a
    /// completion handler — deliberately, because the completion-handler form of
    /// the delegate requirement can silently fail to register at all under the
    /// Xcode 26.2 ClangImporter (PP-4895; see the callbacks in
    /// `MyBooksDownloadCenter` / `TPPNetworkResponder` for the full reasoning).
    /// This is the one place that adapts between the two shapes, so both sites
    /// stay identical and the assumption they rest on is stated once.
    ///
    /// Safe because `handleChallenge` always calls its completion synchronously.
    /// If that ever stopped being true, this returns `.performDefaultHandling`
    /// — a challenge left to the system — rather than hanging the request.
    /// Not `@objc` — the tuple return has no Objective-C representation, and no
    /// Objective-C caller needs it.
    // PUBLIC_INTENT: PalaceNetwork is an SPM package and both consumers of this
    // are in the app target (MyBooksDownloadCenter, TPPNetworkResponder), so
    // `internal` would not reach them. Same visibility as `handleChallenge`,
    // which it wraps; it adds no new capability, only the returning shape the
    // async URLSession delegate callbacks need.
    public func response(
        to challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        var response: (URLSession.AuthChallengeDisposition, URLCredential?) = (.performDefaultHandling, nil)
        handleChallenge(challenge) { response = ($0, $1) }
        return response
    }
}
