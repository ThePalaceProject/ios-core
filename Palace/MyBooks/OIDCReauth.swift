//
//  OIDCReauth.swift
//  Palace
//
//  The borrow flow's OIDC silent re-auth: outcome classification, the retry
//  decision, and the ASWebAuthenticationSession presentation. Errors are
//  classified and a presentation failure is retried once; `session.start()`'s
//  return is checked so a refused presentation cannot leave the continuation
//  hanging, and `resumeOnce` resumes it exactly once. The anchor is the shared
//  `webAuthPresentationAnchor` used by the other OIDC paths.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import AuthenticationServices
import Foundation
import PalaceLogging
import UIKit

extension BorrowOperation {

    // MARK: - OIDC Silent Re-auth (Production Helper)

    /// Static helper that production wiring uses for the
    /// `attemptOIDCReauth` closure. Tests bypass this entirely by
    /// passing a stub closure. Returns `true` if a new token was
    /// obtained, `false` on failure/cancel/no-OIDC-config.
    static func attemptOIDCSilentReauth(userAccount: TPPUserAccount) async -> Bool {
        guard let authDef = userAccount.authDefinition,
              let oidcURL = authDef.oidcAuthenticationUrl else {
            return false
        }

        let callbackScheme = TPPSignInBusinessLogic.oidcCallbackScheme
        let callbackHost = TPPSignInBusinessLogic.oidcCallbackHost
        let redirectURI = "\(callbackScheme)://\(callbackHost)/callback"

        guard var urlComponents = URLComponents(url: oidcURL, resolvingAgainstBaseURL: true) else {
            return false
        }

        let redirectParam = URLQueryItem(name: "redirect_uri", value: redirectURI)
        if urlComponents.queryItems != nil {
            urlComponents.queryItems?.append(redirectParam)
        } else {
            urlComponents.queryItems = [redirectParam]
        }

        guard let finalURL = urlComponents.url else { return false }

        return await runOIDCReauthLoop(url: finalURL,
                                       callbackScheme: callbackScheme,
                                       userAccount: userAccount)
    }

    /// The retry loop, separated from URL-building so tests can drive it: a
    /// unit test cannot synthesize an account that advertises an OIDC URL.
    static func runOIDCReauthLoop(
        url: URL,
        callbackScheme: String,
        userAccount: TPPUserAccount,
        present: (@Sendable (URL, String, TPPUserAccount) async -> OIDCReauthAttempt)? = nil
    ) async -> Bool {
        let finalURL = url

        // One retry, and ONLY for a presentation failure we caused. A patron
        // who declined the sheet must not be shown it again.
        for attempt in 0..<OIDCReauthAttempt.maxPresentationAttempts {
            // `??` cannot be used here: its right-hand side is an autoclosure,
            // which may not be `async`.
            let outcome: OIDCReauthAttempt
            if let present {
                outcome = await present(finalURL, callbackScheme, userAccount)
            } else {
                outcome = await presentOIDCReauthSession(url: finalURL,
                                                        callbackScheme: callbackScheme,
                                                        userAccount: userAccount)
            }

            switch outcome {
            case .succeeded:
                return true

            case let outcome where OIDCReauthAttempt.shouldRetry(outcome, attempt: attempt):
                // iOS refused the anchor (code 3); the patron never saw a sheet.
                // Settle and present once more against a fresh anchor.
                Log.warn(#file, "OIDC silent re-auth: iOS rejected the presentation anchor — retrying once")
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue

            case .presentationFailed:
                Log.error(#file, "OIDC silent re-auth: presentation failed twice — leaving credentials stale, borrow retry will 401")
                return false


            case .patronCancelled:
                Log.info(#file, "OIDC silent re-auth: patron dismissed the sheet — not retrying")
                return false

            case .failed:
                return false
            }
        }

        return false
    }

    /// Presents one OIDC re-auth sheet and classifies the outcome.
    ///
    /// Returns an outcome rather than a `Bool` so the caller can tell a decline
    /// from a presentation failure.
    private static func presentOIDCReauthSession(
        url: URL,
        callbackScheme: String,
        userAccount: TPPUserAccount
    ) async -> OIDCReauthAttempt {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // `session.start()` returns false when iOS refuses to present, and
                // then the completion never fires; that path resumes instead. The
                // flag makes resume one-shot. Main-actor-confined, so a plain Bool.
                var didResume = false
                func resumeOnce(_ outcome: OIDCReauthAttempt) {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: outcome)
                }

                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { @MainActor callbackURL, error in
                    // Explicitly @MainActor: the SDK completion handler is not
                    // annotated, and off-main delivery would race `didResume`
                    // and double-resume a checked continuation (a trap). This is
                    // a compile-time isolation contract, not a runtime hop; the
                    // SIL shows no `hop_to_executor`. The sibling OIDC paths hop
                    // explicitly instead.
                    if let error {
                        // `.canceledLogin` (1) is the patron declining;
                        // `.presentationContextInvalid` (3) is the app failing to
                        // show the sheet. Treating 3 as a decline caused the
                        // reauth loop on build 499.
                        let outcome = OIDCReauthAttempt.classify(error: error)
                        Log.info(#file, "OIDC silent re-auth session ended: \(outcome) (\(error.localizedDescription))")
                        resumeOnce(outcome)
                        return
                    }

                    guard let callbackURL,
                          let payload = callbackURL.query ?? callbackURL.fragment else {
                        resumeOnce(.failed)
                        return
                    }

                    var kvpairs = [String: String]()
                    for param in payload.components(separatedBy: "&") {
                        let elts = param.components(separatedBy: "=")
                        guard elts.count >= 2, let key = elts.first else { continue }
                        kvpairs[key] = elts.dropFirst().joined(separator: "=")
                    }

                    guard let accessToken = kvpairs["access_token"] else {
                        resumeOnce(.failed)
                        return
                    }

                    userAccount.setAuthToken(accessToken, barcode: userAccount.barcode, pin: userAccount.PIN, expirationDate: nil)
                    Log.info(#file, "OIDC silent re-auth: token updated successfully")
                    resumeOnce(.succeeded)
                }

                session.presentationContextProvider = OIDCBorrowPresentationContext.shared
                session.prefersEphemeralWebBrowserSession = false

                // F-016: defer the start so a previous auth modal can finish
                // deallocating; starting during its dealloc makes iOS cancel the
                // session with error 3 (`.presentationContextInvalid`, not a user
                // cancel). 150ms is empirical, not synchronization, so the caller
                // also retries once on code 3.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    // A false return means the session never presented and the
                    // completion will not fire. Classify it as our presentation
                    // failure so the caller's retry can act on it.
                    if !session.start() {
                        Log.warn(#file, "OIDC silent re-auth: session.start() refused to present")
                        resumeOnce(.presentationFailed)
                    }
                }
            }
        }
    }

}

/// How one `ASWebAuthenticationSession` attempt ended.
///
/// `.canceledLogin` (code 1) is the patron declining. `.presentationContextInvalid`
/// (code 3) is the app failing to show the sheet; giving up there strands the
/// patron with stale credentials and a sign-in sheet on every interaction.
enum OIDCReauthAttempt: Equatable {
    case succeeded
    /// The patron dismissed the sheet. Do NOT re-present it.
    case patronCancelled
    /// iOS refused our presentation anchor. Ours to retry.
    case presentationFailed
    case failed

    /// Only our own presentation failures are worth another attempt.
    var isRetryable: Bool { self == .presentationFailed }

    /// The single presentation-attempt bound, shared by the loop and
    /// `shouldRetry`.
    static let maxPresentationAttempts = 2

    /// Whether to present again. A pure function rather than a `switch` in the
    /// loop so a table test can pin the decision and the bound; a pattern in the
    /// loop could gain a case (re-presenting a dismissed sheet) unnoticed.
    static func shouldRetry(_ outcome: OIDCReauthAttempt,
                            attempt: Int,
                            maxAttempts: Int = OIDCReauthAttempt.maxPresentationAttempts) -> Bool {
        outcome.isRetryable && attempt < maxAttempts - 1
    }

    static func classify(error: Error) -> OIDCReauthAttempt {
        guard let sessionError = error as? ASWebAuthenticationSessionError else {
            return .failed
        }
        switch sessionError.code {
        case .canceledLogin:
            return .patronCancelled
        case .presentationContextInvalid, .presentationContextNotProvided:
            return .presentationFailed
        @unknown default:
            return .failed
        }
    }
}

/// Provides a window anchor for `ASWebAuthenticationSession` in the
/// borrow flow's OIDC silent reauth path.
private final class OIDCBorrowPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OIDCBorrowPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // No window may report `isKeyWindow` during a modal dealloc or tab
        // transition, and a scene-less `ASPresentationAnchor()` is rejected with
        // code 3. The shared resolver picks a real, normal-level window from the
        // active scene; the bare anchor is only a last resort.
        UIApplication.shared.webAuthPresentationAnchor ?? ASPresentationAnchor()
    }
}
