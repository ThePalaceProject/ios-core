import UIKit

final class ReaderService {
  static let shared = ReaderService()
  private init() {}

  private lazy var r3Owner: TPPR3Owner = TPPR3Owner()

  func openEPUB(_ book: TPPBook) {
    r3Owner.libraryService.openBook(book, sender: nil) { result in
      switch result {
      case .success(let publication):
        let nav = UINavigationController()
        self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: false)
        TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
      case .failure(let error):
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
    }
  }

  func openSample(_ book: TPPBook, url: URL) {
    r3Owner.libraryService.openSample(book, sampleURL: url, sender: nil) { result in
      switch result {
      case .success(let publication):
        let nav = UINavigationController()
        self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: true)
        TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
      case .failure(let error):
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
    }
  }
}


