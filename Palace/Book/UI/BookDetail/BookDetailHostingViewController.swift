import SwiftUI

@objcMembers class BookDetailHostingController: UIViewController {
  private let book: TPPBook
  private var initialAppearance: UINavigationBarAppearance?

  init(book: TPPBook) {
    self.book = book
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    let bookDetailView = BookDetailView(book: self.book)
    let hostingController = UIHostingController(rootView: bookDetailView)
    addChild(hostingController)

    view.addSubview(hostingController.view)

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])

    hostingController.didMove(toParent: self)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    if initialAppearance == nil {
      initialAppearance = navigationController?.navigationBar.standardAppearance
    }

    setTransparentNavigationBar()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)

//    restoreNavigationBar()
  }

  private func setTransparentNavigationBar() {
    guard let navigationController = navigationController else { return }

    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
    appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

    navigationController.navigationBar.setAppearance(appearance)
    navigationController.navigationBar.isTranslucent = true
    navigationController.navigationBar.forceUpdateAppearance(style: traitCollection.userInterfaceStyle)
  }

  private func restoreNavigationBar() {
//    guard let navigationController = navigationController, let initialAppearance = initialAppearance else { return }
//
//
//    navigationController.navigationBar.setAppearance(initialAppearance)
//    navigationController.navigationBar.isTranslucent = false
////    navigationController.navigationBar.forceUpdateAppearance(style: traitCollection.userInterfaceStyle)
//    additionalSafeAreaInsets.top = 0
  }
}
