import SwiftUI

/// Swift replacement for the legacy TPPCatalogFeedViewController.
/// Wraps the existing SwiftUI `CatalogLaneMoreView` for a given OPDS feed URL.
struct TPPCatalogFeedView: UIViewControllerRepresentable {
  let url: URL
  var title: String?

  init(url: URL, title: String? = nil) {
    self.url = url
    self.title = title
  }

  func makeUIViewController(context: Context) -> UIViewController {
    let view = CatalogLaneMoreView(title: title ?? "", url: url)
    let hosting = UIHostingController(rootView: view)
    return hosting
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    // No-op
  }
}


