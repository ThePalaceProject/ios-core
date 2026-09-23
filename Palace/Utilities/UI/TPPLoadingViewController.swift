import UIKit

protocol TPPLoadingViewController: UIViewController {
    var loadingView: UIView? { get set }
}

extension TPPLoadingViewController {

    @MainActor
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

    // `@MainActor` matches this protocol's `UIViewController` refinement; the
    // previous `DispatchQueue.main.async` hops were defensive main-thread
    // guards now enforced statically, so the UIKit work runs directly.
    @MainActor
    func startLoading() {
        guard loadingView == nil else { return }

        let loadingOverlay = loadingOverlayView()
        if let win = UIApplication.shared.mainKeyWindow {
            win.addSubview(loadingOverlay)
        }
        loadingOverlay.autoPinEdgesToSuperviewEdges()

        loadingView = loadingOverlay
    }

    // Left nonisolated: `CatalogLoadingViewController.deinit` calls this from a
    // nonisolated deinit, so the main-thread hop stays inside the method.
    func stopLoading() {
        DispatchQueue.main.async {
            self.loadingView?.removeFromSuperview()
            self.loadingView = nil
        }
    }
}
