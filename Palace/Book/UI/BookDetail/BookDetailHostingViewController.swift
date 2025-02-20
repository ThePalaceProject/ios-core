import SwiftUI

protocol BookDetailViewDelegate: AnyObject {
  func didChangeToCompactView(_ isCompact: Bool)
  func didUpdateHeaderBackground(isDark: Bool)
}

@objcMembers class BookDetailHostingController: UIViewController, BookDetailViewDelegate {
  private let book: TPPBook
  private var hostingController: UIHostingController<BookDetailView>?
  private var isDarkBackground: Bool = true

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
    setTransparentNavigationBar()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
  }

  func didUpdateHeaderBackground(isDark: Bool) {
    isDarkBackground = isDark
    setTransparentNavigationBar()
  }

  @MainActor
  private func setTransparentNavigationBar() {
    guard let navigationController = navigationController else { return }

    let textColor = isDarkBackground ? UIColor.white : UIColor.black

    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: textColor]
    appearance.largeTitleTextAttributes = [.foregroundColor: textColor]

    navigationController.navigationBar.standardAppearance = appearance
    navigationController.navigationBar.scrollEdgeAppearance = appearance
    navigationController.navigationBar.compactAppearance = appearance
    navigationController.navigationBar.tintColor = textColor

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
