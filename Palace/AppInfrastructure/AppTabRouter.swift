import SwiftUI

enum AppTab: Hashable {
  case catalog
  case myBooks
  case holds
  case settings
}

final class AppTabRouter: ObservableObject {
  @Published var selected: AppTab = .catalog
}

final class AppTabRouterHub {
  static let shared = AppTabRouterHub()
  private init() {}
  weak var router: AppTabRouter?
}


