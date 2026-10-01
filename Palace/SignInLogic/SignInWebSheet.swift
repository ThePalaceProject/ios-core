//
//  SignInWebSheet.swift
//  The Palace Project
//
//  SwiftUI port of TPPCookiesWebViewController: a WKWebView with a Cancel
//  toolbar and a "Loading..." overlay that fades when the first navigation
//  finishes. The visuals match the legacy controller; deviations should be
//  intentional. Navigation policy lives in SignInWebSheetViewModel; the
//  Coordinator forwards WKNavigationDelegate events to it.
//

import SwiftUI
import WebKit
import PalaceLogging
import PalaceCatalog

// MARK: - SignInWebSheet (SwiftUI)

struct SignInWebSheet: View {
    @ObservedObject var viewModel: SignInWebSheetViewModel

    /// Closure the host (presenter / SwiftUI parent) wires up so the sheet
    /// can dismiss itself after Cancel. Kept as a closure rather than
    /// reading from `@Environment(\.dismiss)` so the same view can be used
    /// from a UIHostingController-backed presenter that does its own
    /// dismissal.
    let onDismissRequested: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground)
                    .ignoresSafeArea()

                SignInWebView(viewModel: viewModel)
                    .ignoresSafeArea(edges: .bottom)

                if viewModel.isLoading {
                    loadingOverlay
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: viewModel.isLoading)
            .navigationTitle(NSLocalizedString("Sign In", comment: "Sign-in web view screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(Strings.Generic.cancel) {
                        viewModel.recordCancel()
                        onDismissRequested()
                    }
                }
            }
        }
    }

    // MARK: Loading overlay

    private var loadingOverlay: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .opacity(0.9)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Color(UIColor.systemGray))

                Text(NSLocalizedString("Loading...", comment: "Loading indicator text shown during sign-in"))
                    .font(.body)
                    .foregroundStyle(Color(UIColor.secondaryLabel))
            }
        }
    }
}

// MARK: - SignInWebView (UIViewRepresentable)

/// Bridges a WKWebView into SwiftUI. Owns the Coordinator that forwards
/// navigation events to the view model and translates the model's
/// decisions back into WKNavigationActionPolicy / WKNavigationResponsePolicy.
struct SignInWebView: UIViewRepresentable {
    @ObservedObject var viewModel: SignInWebSheetViewModel

    func makeCoordinator() -> SignInWebViewCoordinator {
        SignInWebViewCoordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // suppress automatic content-inset adjustments that cause the
        // webview to shift/jitter on hover and click in iPad-on-Mac. Mirrors
        // TPPBaseReaderViewController.swift:172-174 which already does this for
        // the Readium WKWebView. Without this, the system repeatedly re-applies
        // safe-area insets to the scroll view on focus events, producing the
        // "buttons shake, hard to trap" symptom users see in SAML flows.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

        Task { @MainActor in
            await viewModel.injectCookiesAndLoad(into: webView.configuration.websiteDataStore.httpCookieStore) { request in
                webView.load(request)
            }
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Coordinator is long-lived; nothing to push back into the WKWebView
        // here. State changes flow through the view model into the loading
        // overlay in the parent view.
    }
}
