import UIKit

protocol LoadingViewController: UIViewController {
  var loadingView: UIView? { get set }
}

extension LoadingViewController {
  
  private func loadingOverlayView() -> UIView {
    let overlayView = UIView()
    overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.7)
    let activityView = UIActivityIndicatorView(style: .whiteLarge)
    overlayView.addSubview(activityView)
    activityView.autoCenterInSuperviewMargins()
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    activityView.startAnimating()
    return overlayView
  }
  
  func startLoading() {
    guard loadingView == nil else { return }
    
    let loadingOverlay = loadingOverlayView()
    if !Thread.isMainThread {
      DispatchQueue.main.async {
        UIApplication.shared.keyWindow?.addSubview(loadingOverlay)
        loadingOverlay.autoPinEdgesToSuperviewEdges()
      }
    } else {
      UIApplication.shared.keyWindow?.addSubview(loadingOverlay)
      loadingOverlay.autoPinEdgesToSuperviewEdges()
    }
    
    loadingView = loadingOverlay
  }
  
  func stopLoading() {
    loadingView?.removeFromSuperview()
    loadingView = nil
  }
}
