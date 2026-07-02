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
// `@preconcurrency` so the iOS-17+ WebKit SDK's `sending decisionHandler`
// parameters on `WKNavigationDelegate.decidePolicyFor` don't trip the
// `complete`-mode "sending value risks data races" diagnostic when the handler
// is carried into the `@MainActor` hop below. The handler is always invoked on
// the main actor (WebKit guarantees delegate callbacks on main; the hop
// re-enters main before calling it), so the pre-concurrency import is a
// suppression of a false positive, not a correctness change.
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
        Task { @MainActor in
            let request = navigationAction.request
            let decision = self.viewModel.decideAction(for: request)
            switch decision {
            case .allow:
                decisionHandler(.allow)

            case .completeLogin(let destination):
                decisionHandler(.cancel)
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                self.viewModel.recordLoginCompletion(destinationURL: destination, cookies: cookies)

            case .cancel, .bookFound, .problemFound:
                // decideAction never returns these; defensive only.
                decisionHandler(.allow)
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
        Task { @MainActor in
            let mime = navigationResponse.response.mimeType
            let decision = self.viewModel.decideResponse(mimeType: mime)
            switch decision {
            case .allow:
                decisionHandler(.allow)

            case .bookFound:
                decisionHandler(.cancel)
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                self.viewModel.recordBookFound(cookies: cookies)

            case .problemFound:
                decisionHandler(.cancel)
                self.viewModel.recordProblem(document: nil)

            case .cancel, .completeLogin:
                // decideResponse never returns these; defensive only.
                decisionHandler(.allow)
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
