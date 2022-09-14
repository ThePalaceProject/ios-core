//
//  EpubSamplePlayerView.swift
//  Palace
//
//  Created by Maurice Carrier on 8/14/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import WebKit

struct EpubSamplePlayerView: View {
  @ObservedObject var model: EpubSamplePlayerModel
  var body: some View {
      contentView
  }

  @ViewBuilder var contentView: some View {
    switch model.state {
    case let .loaded(url):
        WebView(url: url)
    case let .error(error):
      errorView(for: error)
    default:
        loadingView
    }
  }

  @ViewBuilder var loadingView: some View {
    ActivityIndicator(isAnimating: $model.isLoading, style: .large)
  }

  @ViewBuilder func errorView(for error: TPPUserFriendlyError) -> some View {
    Text("Error: \(error.localizedDescription)")
  }
}

struct WebView: UIViewRepresentable {
 
    var url: URL
 
    func makeUIView(context: Context) -> WKWebView {
        return WKWebView()
    }
 
    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
}

@objc class EpubSamplePlayerViewWrapper: NSObject {
  @objc static func create(book: TPPBook, completion: @escaping (String?, Error?) -> Void) {
    guard let model = EpubSamplePlayerModel(book: book) else {
      return
    }

    if model.sample.needsDownload {
      downloadData(url: model.sample.url) { (data, error) in

        guard error == nil else {
          completion(nil, error)
          return
        }

        guard let data = data, let url = save(data: data) else {
          return
        }

        completion(url, nil)
      }
    }
  }

  private static func downloadData(url: URL, completion: @escaping (Data?, Error?) -> Void) {
    TPPNetworkExecutor.shared.GET(url) { result in
      switch result {
      case .failure(let error, _):
        completion(nil, error)
      case .success(let data, _):
        DispatchQueue.main.async {
         completion(data, nil)
        }
      }
    }
  }

  private static func documentDirectory() -> URL {
    let documentDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )[0]
    return documentDirectory.appendingPathComponent("TestApp.epub")
  }

  private static func save(data: Data) -> String? {
    do {
      try data.write(to: documentDirectory())
    } catch {
      print("Error", error)
      return nil
    }
    return documentDirectory().absoluteString
  }
}

