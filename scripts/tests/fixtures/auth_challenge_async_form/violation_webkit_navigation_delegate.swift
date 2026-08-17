// Fixture: WebKit is the OTHER arm of the same collision — when Foundation is
// imported first, this side is the one that stops matching. MUST be flagged.
import WebKit

final class WebSheetCoordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
