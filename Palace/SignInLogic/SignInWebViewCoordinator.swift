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
// `@preconcurrency` for the WebKit SDK's non-Sendable delegate value types
// (`WKNavigationAction`, `WKNavigationResponse`) captured into the async cookie
// `Task` hops below.
@preconcurrency import WebKit
import PalaceLogging

@MainActor
final class SignInWebViewCoordinator: NSObject, WKNavigationDelegate {

    let viewModel: SignInWebSheetViewModel
    weak var webView: WKWebView?

    init(viewModel: SignInWebSheetViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    // MARK: - WKNavigationDelegate

    // The current WebKit SDK annotates `WKNavigationDelegate` (and its
    // `decisionHandler` blocks) `@MainActor` (`WK_SWIFT_UI_ACTOR`). A
    // `nonisolated` witness with a non-`@MainActor` `decisionHandler` no longer
    // matches that `@objc` requirement, so WebKit's `-respondsToSelector:` skips
    // the policy delegate entirely and defaults to allowing every navigation —
    // silently breaking universal-links interception (web-sheet sign-in never
    // completes). Implement it as the `@MainActor` method the SDK expects and
    // call `decisionHandler` synchronously; only the genuinely-async cookie
    // fetch hops through a `Task`.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let request = navigationAction.request
        let decision = viewModel.decideAction(for: request)
        switch decision {
        case .allow:
            decisionHandler(.allow)

        case .completeLogin(let destination):
            decisionHandler(.cancel)
            Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                self.viewModel.recordLoginCompletion(destinationURL: destination, cookies: cookies)
            }

        case .cancel, .bookFound, .problemFound:
            // decideAction never returns these; defensive only.
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        // See the `navigationAction` method above: the current WebKit SDK's
        // `@MainActor` `WKNavigationDelegate` requires an `@MainActor` witness, so
        // this is a plain `@MainActor` method that calls `decisionHandler`
        // synchronously; only the async cookie fetch hops through a `Task`.
        let mime = navigationResponse.response.mimeType
        let decision = viewModel.decideResponse(mimeType: mime)
        switch decision {
        case .allow:
            decisionHandler(.allow)

        case .bookFound:
            decisionHandler(.cancel)
            Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                self.viewModel.recordBookFound(cookies: cookies)
            }

        case .problemFound:
            decisionHandler(.cancel)
            viewModel.recordProblem(document: nil)

        case .cancel, .completeLogin:
            // decideResponse never returns these; defensive only.
            decisionHandler(.allow)
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
