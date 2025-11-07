//
//  EULAView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import WebKit

struct EULAView: View {
  let eulaURL: URL
  let title: String
  
  @State private var isLoading = true
  @State private var showError = false
  @State private var errorMessage: String?
  @Environment(\.dismiss) private var dismiss
  
  init(account: Account) {
    self.eulaURL = account.details?.getLicenseURL(.eula) ?? URL(string: TPPSettings.TPPUserAgreementURLString)!
    self.title = NSLocalizedString("User Agreement", comment: "")
  }
  
  init(nyplURL: Bool = true) {
    self.eulaURL = URL(string: TPPSettings.TPPUserAgreementURLString)!
    self.title = NSLocalizedString("User Agreement", comment: "")
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
    .alert(NSLocalizedString("Connection Failed", comment: ""), isPresented: $showError) {
      Button(Strings.Generic.cancel, role: .cancel) {
        dismiss()
      }
      Button(Strings.Generic.reload) {
        showError = false
        isLoading = true
      }
    } message: {
      Text(errorMessage ?? NSLocalizedString("Unable to load the web page at this time.", comment: ""))
    }
  }
}

// MARK: - WebView Wrapper
private struct WebView: UIViewRepresentable {
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
      timeoutInterval: 15.0
    )
    webView.load(request)
    
    return webView
  }
  
  func updateUIView(_ webView: WKWebView, context: Context) {
    if showError {
      let request = URLRequest(
        url: url,
        cachePolicy: .useProtocolCachePolicy,
        timeoutInterval: 15.0
      )
      webView.load(request)
    }
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

