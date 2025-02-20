import SwiftUI

protocol BookDetailViewDelegate: AnyObject {
  func didChangeToCompactView(_ isCompact: Bool)
}

@objcMembers class BookDetailHostingController: UIViewController, BookDetailViewDelegate {
  private let book: TPPBook
  private var initialAppearance: UINavigationBarAppearance?
  private var hostingController: UIHostingController<BookDetailView>?

  init(book: TPPBook) {
    self.book = book
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    var bookDetailView = BookDetailView(book: self.book)
    bookDetailView.delegate = self
    self.hostingController = UIHostingController(rootView: bookDetailView)

    // Setup the hosting controller
    if let hostingController = self.hostingController {
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

  func didChangeToCompactView(_ isCompact: Bool) {
    DispatchQueue.main.async {
      self.navigationItem.setHidesBackButton(isCompact, animated: true)
    }
  }
}
