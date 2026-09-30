import UIKit

// accesslint:disable A11Y.UIKIT.SCREEN_TITLE - the screen title is set in init as `title = NSLocalizedString(...)`; the detector matches only the literal `self.title`; the window closes on the declaration line because that is the only line this rule reports at — note it therefore also hides this class later LOSING its title
final class CatalogLoadingViewController: UIViewController, @preconcurrency TPPLoadingViewController {
// accesslint:enable A11Y.UIKIT.SCREEN_TITLE
    var loadingView: UIView?

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        title = NSLocalizedString("Loading", comment: "Loading screen title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
