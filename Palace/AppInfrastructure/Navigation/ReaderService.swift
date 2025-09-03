import UIKit

final class ReaderService {
  static let shared = ReaderService()
  private init() {}

  private lazy var r3Owner: TPPR3Owner = TPPR3Owner()

  private func topPresenter() -> UIViewController {
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
       let win = scene.windows.first(where: { $0.isKeyWindow }),
       let root = win.rootViewController {
      var base: UIViewController = root
      while let presented = base.presentedViewController { base = presented }
      return base
    }
    if let win = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
       let root = win.rootViewController {
      var base: UIViewController = root
      while let presented = base.presentedViewController { base = presented }
      return base
    }
    return UIViewController()
  }

  func openEPUB(_ book: TPPBook) {
    r3Owner.libraryService.openBook(book, sender: topPresenter()) { result in
      switch result {
      case .success(let publication):
        let nav = UINavigationController()
        self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: false)
        nav.setNavigationBarHidden(true, animated: false)
        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          coordinator.storeEPUBController(nav, forBookId: book.identifier)
          coordinator.push(.epub(BookRoute(id: book.identifier)))
        } else {
          TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
        }
      case .failure(let error):
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
    }
  }

  func openSample(_ book: TPPBook, url: URL) {
    r3Owner.libraryService.openSample(book, sampleURL: url, sender: topPresenter()) { result in
      switch result {
      case .success(let publication):
        let nav = UINavigationController()
        self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: true)
        nav.setNavigationBarHidden(true, animated: false)
        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          coordinator.storeEPUBController(nav, forBookId: book.identifier)
          coordinator.push(.epub(BookRoute(id: book.identifier)))
        } else {
          TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
        }
      case .failure(let error):
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
    }
  }
}


