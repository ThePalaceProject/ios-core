import UIKit
import SafariServices

/// Routes preview URLs to the right viewer.
///
/// Remote URLs (http/https) require `SFSafariViewController` because
/// third-party preview readers depend on full Safari Web APIs that the
/// embedded `WKWebView` doesn't expose. Local `file://` previews stay in
/// `BundledHTMLViewController` since `SFSafariViewController` can't
/// load file URLs at all.
enum PreviewControllerFactory {

    static func makePreviewController(for url: URL, title: String) -> UIViewController {
        if url.scheme == "http" || url.scheme == "https" {
            return SFSafariViewController(url: url)
        }
        return BundledHTMLViewController(fileURL: url, title: title)
    }
}
