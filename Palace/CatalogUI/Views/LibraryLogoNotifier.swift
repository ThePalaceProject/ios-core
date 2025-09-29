import Foundation
import UIKit

extension Notification.Name {
  static let TPPAccountLogoUpdated = Notification.Name("TPPAccountLogoUpdated")
}

// MARK: - CatalogLogoObserver

final class CatalogLogoObserver: NSObject, ObservableObject, AccountLogoDelegate {
  @Published var token = UUID()

  func logoDidUpdate(in _: Account, to _: UIImage) {
    DispatchQueue.main.async { self.token = UUID() }
  }
}
