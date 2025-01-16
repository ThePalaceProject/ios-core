import SwiftUI

@objcMembers class BookDetailHostingController: UIViewController {
  private let viewModel: BookDetailViewModel

  init(book: TPPBook) {
    self.viewModel = BookDetailViewModel(book: book)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    let bookDetailView = BookDetailView(viewModel: self.viewModel)
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
}
