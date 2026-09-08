//
//  OIDCReauth.swift
//  Palace
//
//  The borrow flow's OIDC silent re-auth: outcome classification, the retry
//  decision, and the ASWebAuthenticationSession presentation.
//
//  Extracted from BorrowOperation.swift. Two SoD reviewers independently asked
//  for this PR to be split, and the `godclass-loc` ratchet then said the same
//  thing mechanically — BorrowOperation is a frozen god-class at a 575-code-line
//  baseline, and this work pushed it past that. The ratchet only ever tightens
//  by hand, so the remedy is to stop growing the hub, not to raise the number.
//
//  Pure move: no behaviour change. `attemptOIDCSilentReauth` stays a static on
//  BorrowOperation so its cross-module caller (MyBooksDownloadCenter) is
//  untouched.
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
    /// - Parameter present: injected presentation seam. Production passes nil and
    ///   gets `presentOIDCReauthSession`; tests script a sequence of outcomes so
    ///   the retry/consent behaviour is driven for real instead of spell-checked
    ///   by a lint. SoD review's verdict was blunt: the fix is a seam, not more
    ///   string assertions.
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

    /// The retry loop, separated from URL-building so it can be DRIVEN.
    ///
    /// `attemptOIDCSilentReauth` returns early unless the account advertises an
    /// OIDC URL, and no unit test can synthesize that — so a test aimed at the
    /// whole function skips, and a skipped test is a silent pass. Splitting the
    /// loop out is what makes the consent and retry behaviour observable.
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
                // iOS refused the anchor (code 3). That is our failure, not a
                // decline: the patron never saw a sheet to decline. Settle and
                // present once more against a freshly-resolved anchor.
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
    /// Split out from `attemptOIDCSilentReauth` so the attempt can be repeated
    /// without re-deriving the URL, and so the outcome is a value the caller can
    /// switch on rather than a bare `Bool` that erases WHY it failed.
    private static func presentOIDCReauthSession(
        url: URL,
        callbackScheme: String,
        userAccount: TPPUserAccount
    ) async -> OIDCReauthAttempt {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // `session.start()` returns false when iOS refuses to present,
                // and in that case the completion handler is NEVER invoked. Without
                // this the continuation would never resume and the borrow would
                // await forever — a hang, worse than the bug being fixed. The guard
                // makes resume one-shot: whichever path arrives first wins and the
                // other is a no-op, so handling the start failure cannot double-resume.
                // MainActor-confined, so a plain flag is sufficient.
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
                    // Explicitly @MainActor rather than relying on inference.
                    // `ASWebAuthenticationSessionCompletionHandler` is NOT
                    // annotated in the SDK, so the closure would inherit
                    // MainActor only by Swift 6 inference over a non-Sendable
                    // parameter. Off-main delivery would race `didResume` and
                    // double-resume a CHECKED continuation — which traps. The
                    // The siblings HOP at runtime (TokenRefreshInterceptor uses
                    // `Task { @MainActor in }`, TPPSignInBusinessLogic+OIDC uses
                    // `TPPMainThreadRun.asyncIfNeeded`). This does NOT — review
                    // measured the SIL and found the annotation emitted then
                    // erased at the block boundary, adding no `hop_to_executor`.
                    // It is a compile-time isolation contract, not a hop, so it
                    // fails fast instead of racing. Do not describe it as
                    // matching the siblings; it does not.
                    if let error {
                        // Classify rather than collapsing every error to `false`.
                        // `.canceledLogin` (1) is the patron declining;
                        // `.presentationContextInvalid` (3) is US failing to put
                        // the sheet on screen. Those demand opposite responses,
                        // and reading 3 as a decline is what produced the
                        // re-auth loop on build 499. The two sibling
                        // implementations of this dance already discriminate
                        // (`TokenRefreshInterceptor`, `TPPSignInBusinessLogic+OIDC`);
                        // this was the drifted third copy.
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

                // F-016: defer the session start so any prior SignInModalHostingController
                // (or the previous SFAuthenticationViewController) has time to finish
                // deallocating. Without this, calling session.start() while a previous
                // auth modal is still in its dealloc cycle produces the runtime warning
                // "Attempting to load the view of a view controller while it is
                // deallocating" and iOS cancels the new session with
                // ASWebAuthenticationSession error 3.
                //
                // Error 3 is `.presentationContextInvalid`, NOT a user cancellation
                // (that is code 1, `.canceledLogin`) — this comment previously said
                // otherwise, which is how the loop stayed misread as a benign decline.
                // The 150ms is an empirical guess rather than synchronization, so the
                // caller also retries once on a code-3 outcome.
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

enum OIDCReauthAttempt: Equatable {
    case succeeded
    /// The patron dismissed the sheet. Do NOT re-present it.
    case patronCancelled
    /// iOS refused our presentation anchor. Ours to retry.
    case presentationFailed
    case failed

    /// Only our own presentation failures are worth another attempt.
    var isRetryable: Bool { self == .presentationFailed }

    /// Whether to present again. THE retry decision, as a value.
    ///
    /// This is a function rather than a `switch` pattern because SoD review
    /// defeated the pattern form three times: a `case` pattern can only be
    /// pinned by a source-text lint, and `XCTAssertTrue(code.contains(...))` is
    /// MONOTONE — it detects deletion but never ADDITION or reordering. So
    /// inserting `case .patronCancelled where attempt == 0: continue` after the
    /// retry case re-presented a dismissed sheet with every test green, and
    /// narrowing `0...1` to `0...0` deleted the retry entirely with every test
    /// green. As a pure function both are ordinary mutants that a table test
    /// kills. `maxAttempts` is a parameter for the same reason — so the bound
    /// itself is asserted rather than spelled into a loop header.
    /// The ONE bound. Previously duplicated as a `let` in the loop and a
    /// defaulted parameter here, which production never passed — two constants
    /// that could silently disagree.
    static let maxPresentationAttempts = 2

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
        // `mainKeyWindow` needs a window currently reporting `isKeyWindow`, and
        // during a modal dealloc or a tab transition none does. The old fallback
        // fabricated a bare `ASPresentationAnchor()` — a UIWindow with NO scene,
        // which is exactly what iOS rejects with `.presentationContextInvalid`
        // (code 3). So the fallback manufactured the very failure it was meant
        // to avoid. Prefer any real window from the active scene; keep the bare
        // anchor only as a last resort so the signature stays total.
        // Shared resolver, so the three OIDC paths cannot drift apart again.
        // It filters out keyboard/hidden/non-normal-level windows, which
        // `windows.first` alone would happily return.
        UIApplication.shared.webAuthPresentationAnchor ?? ASPresentationAnchor()
    }
}
