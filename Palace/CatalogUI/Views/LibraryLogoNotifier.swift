import Foundation
import UIKit

extension Notification.Name {
  static let TPPAccountLogoUpdated = Notification.Name("TPPAccountLogoUpdated")
}

final class CatalogLogoObserver: NSObject, ObservableObject, AccountLogoDelegate {
  @Published var token = UUID()

  func logoDidUpdate(in account: Account, to newLogo: UIImage) {
    DispatchQueue.main.async { self.token = UUID() }
  }
}


