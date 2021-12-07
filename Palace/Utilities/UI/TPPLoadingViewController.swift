import UIKit

protocol TPPLoadingViewController: UIViewController {
  var loadingView: UIView? { get set }
}

extension TPPLoadingViewController {
  
  private func loadingOverlayView() -> UIView {
    let overlayView = UIView()
    overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.7)
    let activityView = UIActivityIndicatorView(style: .large)
    overlayView.addSubview(activityView)
    activityView.autoCenterInSuperviewMargins()
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    activityView.startAnimating()
    return overlayView
  }
  
  func startLoading() {
    guard loadingView == nil else { return }
    
    let loadingOverlay = loadingOverlayView()
      DispatchQueue.main.async {
        UIApplication.shared.keyWindow?.addSubview(loadingOverlay)
        loadingOverlay.autoPinEdgesToSuperviewEdges()
      }
    
    loadingView = loadingOverlay
  }
  
  func stopLoading() {
    DispatchQueue.main.async {
      self.loadingView?.removeFromSuperview()
      self.loadingView = nil
    }
  }
}

