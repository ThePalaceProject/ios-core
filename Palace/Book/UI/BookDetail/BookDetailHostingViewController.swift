import SwiftUI

@objcMembers class BookDetailHostingController: UIViewController {
  private let book: TPPBook

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

    setTransparentNavigationBar()
  }

  private func setTransparentNavigationBar() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground() // ✅ Ensures transparency
    appearance.backgroundColor = .clear // ✅ No background color
    appearance.shadowColor = .clear // ✅ Removes bottom shadow
    appearance.titleTextAttributes = [.foregroundColor: UIColor.white] // ✅ White title for visibility
    appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

    UINavigationBar.appearance().setAppearance(appearance)
  }
}
