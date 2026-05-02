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
import WebKit
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
        let request = navigationAction.request
        Task { @MainActor in
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
        let mime = navigationResponse.response.mimeType
        Task { @MainActor in
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
