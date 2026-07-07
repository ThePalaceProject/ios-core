//
//  SignInWebViewCoordinator.swift
//  The Palace Project
//
//  WKNavigationDelegate that forwards events to SignInWebSheetViewModel
//  and applies the model's decisions back to the WKWebView. Held by the
//  UIViewRepresentable's Coordinator slot. Public so integration tests
//  can construct it directly against a real WKWebView without standing
//  up the full SwiftUI view tree.
//

import Foundation
// `@preconcurrency` for the iOS-17+ WebKit SDK's non-Sendable delegate types
// carried into the `@MainActor` hops below (`WKNavigationAction`,
// `WKNavigationResponse`, `WKWebView`). The `sending decisionHandler` closures
// are additionally boxed in `DecisionHandlerBox` (see below) — WebKit guarantees
// delegate callbacks on main and each hop re-enters main before invoking the
// handler, so the box waives no real race, it satisfies the `@Sendable` capture.
@preconcurrency import WebKit
import PalaceLogging

/// Sendable carrier for WebKit's non-Sendable `decisionHandler` closures
/// (`@escaping (WKNavigationActionPolicy) -> Void` /
/// `@escaping (WKNavigationResponsePolicy) -> Void`) captured by the
/// `@Sendable` `Task { @MainActor in }` hops in the `decidePolicyFor` delegate
/// methods below. Boxing lets the Task capture a Sendable carrier instead of the
/// raw handler, clearing the "sending 'decisionHandler' risks data races"
/// diagnostic. INVARIANT — WebKit delivers `WKNavigationDelegate` callbacks on
/// the main thread and each hop re-enters the main actor before calling the
/// handler, so the boxed closure is invoked exactly once, on main, from inside
/// that single Task. Mirrors the carrier-box precedent (`ReadiumBookmarkBox`).
private final class DecisionHandlerBox<Policy>: @unchecked Sendable {
    let call: (Policy) -> Void
    init(_ call: @escaping (Policy) -> Void) { self.call = call }
}

@MainActor
final class SignInWebViewCoordinator: NSObject, WKNavigationDelegate {

    let viewModel: SignInWebSheetViewModel
    weak var webView: WKWebView?

    init(viewModel: SignInWebSheetViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // `WKNavigationAction.request` is main actor-isolated; read it inside the
        // @MainActor hop (capturing `navigationAction`, like `webView` already
        // is) rather than in this nonisolated delegate body, which would trip the
        // `targeted` "main actor-isolated property referenced from nonisolated
        // context" diagnostic. `URLRequest` is a value type, so the deferred read
        // observes the same request.
        // Swift 6 `complete`: box the non-Sendable `decisionHandler` before the
        // `@Sendable` `Task { @MainActor in }` hop (see `DecisionHandlerBox`);
        // WebKit delivers on main and the hop re-enters main before calling it.
        let decisionBox = DecisionHandlerBox(decisionHandler)
        Task { @MainActor in
            let request = navigationAction.request
            let decision = self.viewModel.decideAction(for: request)
            switch decision {
            case .allow:
                decisionBox.call(.allow)

            case .completeLogin(let destination):
                decisionBox.call(.cancel)
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                self.viewModel.recordLoginCompletion(destinationURL: destination, cookies: cookies)

            case .cancel, .bookFound, .problemFound:
                // decideAction never returns these; defensive only.
                decisionBox.call(.allow)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // `WKNavigationResponse.response` is main actor-isolated; read its
        // `mimeType` inside the @MainActor hop (capturing `navigationResponse`)
        // rather than in this nonisolated delegate body, which would trip the
        // `targeted` "main actor-isolated property referenced from nonisolated
        // context" diagnostic.
        // Swift 6 `complete`: box the non-Sendable `decisionHandler` before the
        // `@Sendable` `Task { @MainActor in }` hop (see `DecisionHandlerBox`);
        // WebKit delivers on main and the hop re-enters main before calling it.
        let decisionBox = DecisionHandlerBox(decisionHandler)
        Task { @MainActor in
            let mime = navigationResponse.response.mimeType
            let decision = self.viewModel.decideResponse(mimeType: mime)
            switch decision {
            case .allow:
                decisionBox.call(.allow)

            case .bookFound:
                decisionBox.call(.cancel)
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                self.viewModel.recordBookFound(cookies: cookies)

            case .problemFound:
                decisionBox.call(.cancel)
                self.viewModel.recordProblem(document: nil)

            case .cancel, .completeLogin:
                // decideResponse never returns these; defensive only.
                decisionBox.call(.allow)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.viewModel.didStartProvisionalNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.viewModel.didFinishNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.error(#file, "WebView navigation failed: \(error.localizedDescription)")
        Task { @MainActor in self.viewModel.didFailNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.error(#file, "WebView provisional navigation failed: \(error.localizedDescription)")
        Task { @MainActor in self.viewModel.didFailNavigation() }
    }
}

// WKHTTPCookieStore.allCookies() is a system API on iOS 17+; we use it
// directly. The setCookie(_:) async wrapper lives in
// SignInWebSheetViewModel.swift's CookieStoreInjecting conformance.
