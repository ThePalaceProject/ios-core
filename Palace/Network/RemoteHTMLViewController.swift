import PureLayout
import UIKit
import WebKit

/// Similar functionality to BundledHTMLViewController, except for loading remote HTTP URL's where
/// it does not make sense in certain contexts to have bundled resources loaded.
@objcMembers final class RemoteHTMLViewController: UIViewController, WKNavigationDelegate {
  let fileURL: URL
  let failureMessage: String
  var webView: WKWebView
  var activityView: UIActivityIndicatorView!

  required init(URL: URL, title: String, failureMessage: String) {
    fileURL = URL
    self.failureMessage = failureMessage
    webView = WKWebView()

    super.init(nibName: nil, bundle: nil)

    self.title = title
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    webView.frame = view.frame
    webView.navigationDelegate = self
    webView.backgroundColor = UIColor.white
    webView.allowsBackForwardNavigationGestures = true

    view.addSubview(webView)
    webView.autoPinEdgesToSuperviewEdges()

    let request = URLRequest(url: fileURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10.0)
    webView.load(request)

    activityViewShouldShow(true)
  }

  func activityViewShouldShow(_ shouldShow: Bool) {
    if shouldShow == true {
      activityView = UIActivityIndicatorView(style: .medium)
      view.addSubview(activityView)
      activityView.autoCenterInSuperview()
      activityView.startAnimating()
    } else {
      activityView?.stopAnimating()
      activityView?.removeFromSuperview()
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
    activityViewShouldShow(false)
    let alert = UIAlertController(
      title: Strings.Error.connectionFailed,
      message: error.localizedDescription,
      preferredStyle: .alert
    )
    let action1 = UIAlertAction(title: Strings.Generic.cancel, style: .destructive) { _ in
      _ = self.navigationController?.popViewController(animated: true)
    }
    let action2 = UIAlertAction(title: Strings.Generic.reload, style: .destructive) { _ in
      var urlRequest = URLRequest(url: self.fileURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10.0)
      webView.load(urlRequest.applyCustomUserAgent())
    }

    alert.addAction(action1)
    alert.addAction(action2)
    present(alert, animated: true, completion: nil)
  }

  func webView(
    _: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }

    if UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url)
    }
    decisionHandler(.cancel)
  }

  func webView(_: WKWebView, didFinish _: WKNavigation!) {
    activityViewShouldShow(false)
  }

  func webView(
    _: WKWebView,
    didFail _: WKNavigation!,
    withError _: Error
  ) {
    activityViewShouldShow(false)
  }
}
