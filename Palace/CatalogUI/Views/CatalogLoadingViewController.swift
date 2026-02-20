import UIKit

// accesslint:disable A11Y.UIKIT.VC_TITLE - Title set in viewDidLoad
final class CatalogLoadingViewController: UIViewController, TPPLoadingViewController {
    var loadingView: UIView?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Loading", comment: "Loading screen title")
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
