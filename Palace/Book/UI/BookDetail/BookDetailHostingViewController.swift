import SwiftUI

@objcMembers class BookDetailHostingController: UIViewController {
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

    self.hostingController = UIHostingController(rootView: BookDetailView(book: self.book))

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
    navigationController?.setNavigationBarHidden(true, animated: false)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
  }

  func didChangeToCompactView(_ isCompact: Bool) {
    DispatchQueue.main.async {
      self.navigationItem.setHidesBackButton(isCompact, animated: true)
    }
  }
}
