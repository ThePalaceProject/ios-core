import UIKit
import ReadiumShared

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

  @MainActor
  func openEPUB(_ book: TPPBook) {
    r3Owner.libraryService.openBook(book, sender: topPresenter()) { result in
      switch result {
      case .success(let publication):
        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          coordinator.store(book: book)
          coordinator.storeEPUBPublication(publication, forBookId: book.identifier, forSample: false)
          coordinator.push(.epub(BookRoute(id: book.identifier)))
        } else {
          let nav = UINavigationController()
          self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: false)
          TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
        }
      case .failure(let error):
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
    }
  }

  @MainActor
  func openSample(_ book: TPPBook, url: URL) {
    r3Owner.libraryService.openSample(book, sampleURL: url, sender: topPresenter()) { result in
      switch result {
      case .success(let publication):
        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          coordinator.store(book: book)
          coordinator.presentEPUBSample(publication, forBookId: book.identifier)
        } else {
          let nav = UINavigationController()
          self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: true)
          TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
        }
      case .failure(let error):
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
    }
  }
  
  // MARK: - View Controller Creation (for SwiftUI integration)
  
  /// Creates an EPUB view controller from a publication (used by EPUBReaderView)
  @MainActor
  func makeEPUBViewController(for publication: Publication, book: TPPBook, forSample: Bool) async throws -> UIViewController {
    let bookRegistry = TPPBookRegistry.shared
    let lastSavedLocation = bookRegistry.location(forIdentifier: book.identifier)
    let initialLocator = await lastSavedLocation?.convertToLocator(publication: publication)
    
    // Cast to concrete ReaderModule to access formatModules
    guard let readerModule = r3Owner.readerModule as? ReaderModule else {
      throw ReaderError.formatNotSupported
    }
    
    let formatModule = readerModule.formatModules.first { $0.supports(publication) }
    guard let epubModule = formatModule else {
      throw ReaderError.formatNotSupported
    }
    
    let readerVC = try await epubModule.makeReaderViewController(
      for: publication,
      book: book,
      initialLocation: initialLocator,
      forSample: forSample
    )
    
    readerVC.hidesBottomBarWhenPushed = true
    return readerVC
  }
}


