import UIKit

final class CatalogLoadingViewController: UIViewController, TPPLoadingViewController {
  var loadingView: UIView?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TPPConfiguration.backgroundColor()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startLoading()
  }

  deinit {
    stopLoading()
  }
}
