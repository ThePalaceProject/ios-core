//
//  EULAView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import WebKit

struct EULAView: View {
  typealias DisplayStrings = Strings.Settings
  
  private enum Constants {
    static let requestTimeout: TimeInterval = 15.0
  }
  
  let eulaURL: URL
  let title: String
  
  @State private var isLoading = true
  @State private var showError = false
  @State private var errorMessage: String?
  @Environment(\.dismiss) private var dismiss
  
  init(account: Account) {
    eulaURL = account.details?.getLicenseURL(.eula) ?? URL(string: TPPSettings.TPPUserAgreementURLString)!
    title = Strings.Settings.eula
  }
  
  init(nyplURL: Bool = true) {
    eulaURL = URL(string: TPPSettings.TPPUserAgreementURLString)!
    title = Strings.Settings.eula
  }
  
  var body: some View {
    ZStack {
      WebView(
        url: eulaURL,
        isLoading: $isLoading,
        showError: $showError,
        errorMessage: $errorMessage
      )
      
      if isLoading {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .alert(Strings.Error.connectionFailed, isPresented: $showError) {
      Button(Strings.Generic.cancel, role: .cancel) {
        dismiss()
      }
      Button(Strings.Generic.reload) {
        showError = false
        isLoading = true
      }
    } message: {
      Text(errorMessage ?? Strings.Error.pageLoadFailedError)
    }
  }
}

// MARK: - WebView Wrapper
private struct WebView: UIViewRepresentable {
  private enum Constants {
    static let requestTimeout: TimeInterval = 15.0
  }
  
  let url: URL
  @Binding var isLoading: Bool
  @Binding var showError: Bool
  @Binding var errorMessage: String?
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  func makeUIView(context: Context) -> WKWebView {
    let webView = WKWebView()
    webView.backgroundColor = TPPConfiguration.backgroundColor()
    webView.navigationDelegate = context.coordinator
    
    let request = URLRequest(
      url: url,
      cachePolicy: .useProtocolCachePolicy,
      timeoutInterval: Constants.requestTimeout
    )
    webView.load(request)
    
    return webView
  }
  
  func updateUIView(_ webView: WKWebView, context: Context) {
    guard showError else { return }
    
    let request = URLRequest(
      url: url,
      cachePolicy: .useProtocolCachePolicy,
      timeoutInterval: Constants.requestTimeout
    )
    webView.load(request)
  }
  
  class Coordinator: NSObject, WKNavigationDelegate {
    var parent: WebView
    
    init(_ parent: WebView) {
      self.parent = parent
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      parent.isLoading = false
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      parent.isLoading = false
      parent.errorMessage = error.localizedDescription
      parent.showError = true
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      parent.isLoading = false
      parent.errorMessage = error.localizedDescription
      parent.showError = true
    }
  }
}

